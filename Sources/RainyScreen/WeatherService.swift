import AppKit
@preconcurrency import CoreLocation
import Foundation
import RainCore

struct WeatherLocation: Equatable {
    let name: String
    let latitude: Double
    let longitude: Double
}

@MainActor final class WeatherService: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let urlSession: URLSession
    private let defaults: UserDefaults
    private var timer: Timer?
    private var locationTimeout: Timer?
    private var task: Task<Void, Never>?
    private var lastLocation: CLLocation?
    private var lastCurrentLocation: WeatherLocation?
    private var lastWeather: WeatherResponse.Current?
    private(set) var manualLocation: WeatherLocation?
    private var enabled = false
    private var pendingRefreshAfterAuthorization = false
    private var activeLocationRequestID: UInt64?
    private var activeLocationAllowsWhenDisabled = false
    private var requestGeneration: UInt64 = 0
    private var cachedStatus: CachedStatus = .preparing

    var onUpdate: ((Float, String) -> Void)?

    var usesManualLocation: Bool { manualLocation != nil }
    var locationTitle: String { manualLocation?.name ?? currentLocationName }
    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    private enum DefaultsKey {
        static let name = "weather.manual.name"
        static let latitude = "weather.manual.latitude"
        static let longitude = "weather.manual.longitude"
    }

    private enum CachedStatus {
        case preparing
        case waitingForAuthorization
        case checkingLocation
        case updating(location: DisplayLocation)
        case usingPreviousLocation(location: DisplayLocation)
        case locationUnavailable
        case locationDenied
        case staleWeather
        case weather(location: DisplayLocation, value: WeatherResponse.Current)
        case weatherFetchFailed
    }

    private enum DisplayLocation {
        case current
        case manual(WeatherLocation)

        var name: String {
            switch self {
            case .current:
                return L10n.text("現在地", "Current Location")
            case let .manual(location):
                return location.name
            }
        }
    }

    init(urlSession: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.urlSession = urlSession
        self.defaults = defaults
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 1000
        loadManualLocation()
    }

    func start() {
        enabled = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        enabled = false
        timer?.invalidate()
        timer = nil
        cancelCurrentRequest()
    }

    /// Fetches weather once without enabling the automatic weather mode.
    /// This is used by Settings while the selected app mode is stopped or manual rain.
    func refreshOnce() {
        beginRefresh(allowWhenDisabled: true)
    }

    func setManualLocation(_ location: WeatherLocation) {
        guard location.latitude.isFinite, location.longitude.isFinite,
              (-90...90).contains(location.latitude), (-180...180).contains(location.longitude) else { return }

        cancelCurrentRequest()
        manualLocation = location
        defaults.set(location.name, forKey: DefaultsKey.name)
        defaults.set(location.latitude, forKey: DefaultsKey.latitude)
        defaults.set(location.longitude, forKey: DefaultsKey.longitude)
        lastWeather = nil
        lastLocation = nil
        emit(.preparing, intensity: 0)
    }

    func useCurrentLocation() {
        cancelCurrentRequest()
        manualLocation = nil
        defaults.removeObject(forKey: DefaultsKey.name)
        defaults.removeObject(forKey: DefaultsKey.latitude)
        defaults.removeObject(forKey: DefaultsKey.longitude)
        lastWeather = nil
        lastLocation = nil
        emit(.preparing, intensity: 0)
    }

    /// Re-emits the cached semantic status using the currently selected language.
    /// No network request is made.
    func localizationDidChange() {
        if case let .weather(_, value) = cachedStatus, !value.isFresh(at: Date()) {
            emit(.staleWeather, intensity: 0)
        } else {
            emit(cachedStatus)
        }
    }

    func searchLocations(_ query: String) async throws -> [WeatherLocation] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        if let appleResults = try? await searchAppleLocations(query), !appleResults.isEmpty {
            return appleResults
        }
        return try await searchOpenMeteoLocations(query)
    }

    private func searchOpenMeteoLocations(_ query: String) async throws -> [WeatherLocation] {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "6"),
            URLQueryItem(name: "language", value: L10n.isJapanese ? "ja" : "en"),
            URLQueryItem(name: "format", value: "json")
        ]
        do {
            let request = URLRequest(url: components.url!, timeoutInterval: 15)
            let (data, response) = try await urlSession.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw Self.weatherError(
                    japanese: "地点検索サービスの応答エラー",
                    english: "The location search service returned an error.",
                    code: 2
                )
            }
            let payload = try JSONDecoder().decode(GeocodingResponse.self, from: data)
            return (payload.results ?? []).map { result in
                var parts = [result.name]
                if let admin1 = result.admin1, !admin1.isEmpty, admin1 != result.name { parts.append(admin1) }
                if let country = result.country, !country.isEmpty, !parts.contains(country) { parts.append(country) }
                return WeatherLocation(name: parts.joined(separator: " · "), latitude: result.latitude, longitude: result.longitude)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NSError where error.domain == "Weather" {
            throw error
        } catch {
            throw Self.weatherError(
                japanese: "地点検索に失敗しました。ネットワーク接続を確認してください。",
                english: "Location search failed. Check your network connection.",
                code: 3
            )
        }
    }

    private func searchAppleLocations(_ query: String) async throws -> [WeatherLocation] {
        let geocoder = CLGeocoder()
        return try await withCheckedThrowingContinuation { continuation in
            geocoder.geocodeAddressString(
                query,
                in: nil,
                preferredLocale: Locale(identifier: L10n.isJapanese ? "ja_JP" : "en_US")
            ) { [geocoder] placemarks, error in
                _ = geocoder
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let locations = (placemarks ?? []).compactMap { placemark -> WeatherLocation? in
                    guard let coordinate = placemark.location?.coordinate,
                          coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return nil }
                    var parts: [String] = []
                    for part in [placemark.locality, placemark.administrativeArea, placemark.country] {
                        if let part, !part.isEmpty, !parts.contains(part) { parts.append(part) }
                    }
                    let name = parts.isEmpty ? (placemark.name ?? query) : parts.joined(separator: " · ")
                    return WeatherLocation(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude)
                }
                continuation.resume(returning: locations)
            }
        }
    }

    /// Refreshes only while the weather mode is enabled.
    /// The automatic timer remains owned by `start()` and is never created here.
    func refresh() {
        guard enabled else { return }
        beginRefresh(allowWhenDisabled: false)
    }

    private func beginRefresh(allowWhenDisabled: Bool) {
        guard enabled || allowWhenDisabled else { return }

        cancelCurrentRequest()
        let requestID = requestGeneration

        if let manualLocation {
            emit(.updating(location: .manual(manualLocation)), intensity: freshIntensity)
            fetch(manualLocation, requestID: requestID, allowWhenDisabled: allowWhenDisabled)
            return
        }

        switch manager.authorizationStatus {
        case .notDetermined:
            pendingRefreshAfterAuthorization = true
            emit(.waitingForAuthorization, intensity: 0)
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorized:
            beginCurrentLocationRequest(requestID: requestID, allowWhenDisabled: allowWhenDisabled)
        default:
            pendingRefreshAfterAuthorization = false
            if let fallback = lastCurrentLocation {
                emit(.usingPreviousLocation(location: .current), intensity: freshIntensity)
                fetch(fallback, requestID: requestID, allowWhenDisabled: allowWhenDisabled)
            } else {
                lastWeather = nil
                emit(.locationDenied, intensity: 0)
            }
        }
    }

    private func beginCurrentLocationRequest(requestID: UInt64, allowWhenDisabled: Bool) {
        pendingRefreshAfterAuthorization = false
        activeLocationRequestID = requestID
        activeLocationAllowsWhenDisabled = allowWhenDisabled
        emit(.updating(location: .current), intensity: freshIntensity)
        manager.startUpdatingLocation()
        locationTimeout?.invalidate()
        locationTimeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.activeLocationRequestID == requestID,
                      self.isRequestCurrent(requestID, allowWhenDisabled: allowWhenDisabled) else { return }
                self.finishCurrentLocationRequest()
                if let location = self.lastLocation,
                   abs(location.timestamp.timeIntervalSinceNow) < 1800 {
                    self.fetch(
                        WeatherLocation(
                            name: self.currentLocationName,
                            latitude: location.coordinate.latitude,
                            longitude: location.coordinate.longitude
                        ),
                        requestID: requestID,
                        allowWhenDisabled: allowWhenDisabled
                    )
                } else if let fallback = self.lastCurrentLocation {
                    self.emit(.usingPreviousLocation(location: .current), intensity: self.freshIntensity)
                    self.fetch(fallback, requestID: requestID, allowWhenDisabled: allowWhenDisabled)
                } else {
                    self.emit(.locationUnavailable, intensity: 0)
                }
            }
        }
    }

    private var freshIntensity: Float {
        guard let lastWeather, lastWeather.isFresh(at: Date()) else { return 0 }
        return lastWeather.intensity
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        guard enabled || pendingRefreshAfterAuthorization else { return }
        beginRefresh(allowWhenDisabled: !enabled)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let requestID = activeLocationRequestID,
              isRequestCurrent(requestID, allowWhenDisabled: activeLocationAllowsWhenDisabled),
              let location = locations.last,
              location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 300 else { return }

        let allowWhenDisabled = activeLocationAllowsWhenDisabled
        finishCurrentLocationRequest()
        lastLocation = location
        fetch(
            WeatherLocation(
                name: currentLocationName,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            ),
            requestID: requestID,
            allowWhenDisabled: allowWhenDisabled
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let requestID = activeLocationRequestID,
              isRequestCurrent(requestID, allowWhenDisabled: activeLocationAllowsWhenDisabled) else { return }

        if let locationError = error as? CLError, locationError.code == .locationUnknown {
            emit(.checkingLocation, intensity: freshIntensity)
            return
        }

        let allowWhenDisabled = activeLocationAllowsWhenDisabled
        finishCurrentLocationRequest()
        if let locationError = error as? CLError, locationError.code == .denied,
           lastCurrentLocation == nil {
            emit(.locationDenied, intensity: freshIntensity)
            return
        }
        if let fallback = lastCurrentLocation {
            emit(.usingPreviousLocation(location: .current), intensity: freshIntensity)
            fetch(fallback, requestID: requestID, allowWhenDisabled: allowWhenDisabled)
        } else {
            emit(.locationUnavailable, intensity: freshIntensity)
        }
    }

    private func fetch(_ location: WeatherLocation, requestID: UInt64, allowWhenDisabled: Bool) {
        task?.cancel()
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", location.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", location.longitude)),
            URLQueryItem(name: "current", value: "rain,showers,weather_code"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: "1")
        ]
        let session = urlSession
        task = Task { [weak self] in
            do {
                let (data, response) = try await session.data(
                    for: URLRequest(url: url.url!, timeoutInterval: 20)
                )
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    throw Self.weatherError(
                        japanese: "天気サービスの応答エラー",
                        english: "The weather service returned an error.",
                        code: 1
                    )
                }
                let weather = try JSONDecoder().decode(WeatherResponse.self, from: data).current
                guard let self,
                      self.isRequestCurrent(requestID, allowWhenDisabled: allowWhenDisabled) else { return }
                guard weather.isFresh(at: Date()) else {
                    self.lastWeather = nil
                    self.emit(.staleWeather, intensity: 0)
                    return
                }
                self.lastWeather = weather
                if self.manualLocation == nil { self.lastCurrentLocation = location }
                let displayLocation: DisplayLocation = self.manualLocation == nil
                    ? .current
                    : .manual(location)
                self.emit(.weather(location: displayLocation, value: weather), intensity: weather.intensity)
            } catch is CancellationError {
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.isRequestCurrent(requestID, allowWhenDisabled: allowWhenDisabled) else { return }
                self.emit(.weatherFetchFailed, intensity: self.freshIntensity)
            }
        }
    }

    private func cancelCurrentRequest() {
        requestGeneration &+= 1
        pendingRefreshAfterAuthorization = false
        activeLocationRequestID = nil
        activeLocationAllowsWhenDisabled = false
        locationTimeout?.invalidate()
        locationTimeout = nil
        manager.stopUpdatingLocation()
        task?.cancel()
        task = nil
    }

    private func finishCurrentLocationRequest() {
        activeLocationRequestID = nil
        activeLocationAllowsWhenDisabled = false
        locationTimeout?.invalidate()
        locationTimeout = nil
        manager.stopUpdatingLocation()
    }

    private func isRequestCurrent(_ requestID: UInt64, allowWhenDisabled: Bool) -> Bool {
        requestGeneration == requestID && (enabled || allowWhenDisabled)
    }

    private func emit(_ status: CachedStatus, intensity: Float? = nil) {
        cachedStatus = status
        let resolvedIntensity: Float
        if let intensity {
            resolvedIntensity = intensity
        } else if case let .weather(_, value) = status {
            resolvedIntensity = value.intensity
        } else {
            resolvedIntensity = freshIntensity
        }
        onUpdate?(resolvedIntensity, label(for: status))
    }

    private func label(for status: CachedStatus) -> String {
        switch status {
        case .preparing:
            return L10n.text("現在地の天気を準備中", "Preparing weather for the current location")
        case .waitingForAuthorization:
            return L10n.text("現在地の利用許可を待っています", "Waiting for location permission")
        case .checkingLocation:
            return L10n.text("現在地を確認中…", "Checking current location…")
        case let .updating(location):
            return L10n.text("\(location.name)の天気を更新中…", "Updating weather for \(location.name)…")
        case let .usingPreviousLocation(location):
            return L10n.text(
                "現在地を利用できないため、\(location.name)で更新中…",
                "Current location unavailable; updating with \(location.name)…"
            )
        case .locationUnavailable:
            return L10n.text(
                "現在地を取得できません。Wi-Fi・位置情報設定を確認",
                "Unable to obtain the current location. Check Wi-Fi and Location Services."
            )
        case .locationDenied:
            return L10n.text(
                "位置情報が未許可です（設定から許可できます）",
                "Location access is not authorized. You can allow it in Settings."
            )
        case .staleWeather:
            return L10n.text("天気データが古いため雨を停止中", "Weather data is stale; rain stopped")
        case let .weather(location, value):
            let amount = String(format: "%.2f", value.rain + value.showers)
            let rainLabel = value.isRaining
                ? L10n.text("雨", "Rain") + " · " + amount + " " + L10n.text("mm / 15分", "mm / 15 min")
                : L10n.text("現在は雨なし", "No rain now")
            let time = timeLabel(for: Date(timeIntervalSince1970: value.time))
            return "\(location.name): \(rainLabel) · \(time)"
        case .weatherFetchFailed:
            return enabled
                ? L10n.text("天気取得失敗（5分後に再試行）", "Weather fetch failed (retrying in 5 minutes)")
                : L10n.text("天気取得に失敗しました", "Weather fetch failed")
        }
    }

    private func timeLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.isJapanese ? "ja_JP" : "en_US")
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let time = formatter.string(from: date)
        return L10n.isJapanese ? "\(time) 更新" : "Updated \(time)"
    }

    private var currentLocationName: String {
        L10n.text("現在地", "Current Location")
    }

    private static func weatherError(japanese: String, english: String, code: Int) -> NSError {
        NSError(
            domain: "Weather",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: L10n.text(japanese, english)]
        )
    }

    private func loadManualLocation() {
        guard let name = defaults.string(forKey: DefaultsKey.name),
              let latitude = defaults.object(forKey: DefaultsKey.latitude) as? Double,
              let longitude = defaults.object(forKey: DefaultsKey.longitude) as? Double,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return }
        manualLocation = WeatherLocation(name: name, latitude: latitude, longitude: longitude)
    }
}

private struct GeocodingResponse: Decodable {
    let results: [GeocodingResult]?
}

private struct GeocodingResult: Decodable {
    let name: String
    let latitude: Double
    let longitude: Double
    let country: String?
    let admin1: String?
}
