import AppKit
import MetalKit
import ServiceManagement
import UniformTypeIdentifiers
import RainCore
@preconcurrency import CoreLocation

final class RainWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private let supportedFrameRates = [24, 30, 60]
private let mistStrength: Float = 0.35
private let rainStrengthOptions: [(label: String, value: Float)] = [
    ("霧雨（細粒・結露）", 0.35),
    ("弱", 0.8),
    ("中（これまでの強さ）", 1.4),
    ("強", 2.4),
    ("大雨", 3.8),
    ("豪雨（大粒・高速）", 5.6)
]
private let randomStrengthIntervals: [(label: String, seconds: TimeInterval)] = [
    ("頻繁（15秒）", 15),
    ("短め（30秒）", 30),
    ("標準（1分）", 60),
    ("ゆったり（3分）", 180),
    ("のんびり（5分）", 300)
]

final class TransparentMetalView: MTKView {
    override var isOpaque: Bool { false }
}

@MainActor final class Overlay {
    let window: NSWindow
    let view: MTKView
    let renderer: RainRenderer
    let displayID: CGDirectDisplayID
    init(screen: NSScreen, device: MTLDevice, framesPerSecond: Int = 30) throws {
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        window = RainWindow(contentRect:screen.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.ignoresMouseEvents = true
        // Keep system menu bar available as a permanent escape route.
        window.level = NSWindow.Level(rawValue:Int(CGWindowLevelForKey(.statusWindow))-1)
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        window.hidesOnDeactivate = false
        view = TransparentMetalView(frame:NSRect(origin:.zero,size:screen.frame.size),device:device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0,0,0,0)
        view.wantsLayer = true; view.layer?.isOpaque = false
        view.preferredFramesPerSecond = framesPerSecond
        view.autoResizeDrawable = false
        // NSScreen frames are expressed in logical points. On a HiDPI display
        // that leaves the overlay and its ScreenCaptureKit source at half the
        // physical resolution, which becomes visibly soft after compositing.
        let scale = max(1,screen.backingScaleFactor)
        view.drawableSize = CGSize(width:screen.frame.width*scale,
                                   height:screen.frame.height*scale)
        renderer = try RainRenderer(view:view,screenFrame:screen.frame,seed:UInt64(displayID)+42)
        view.delegate = renderer
        window.contentView = view
    }
    func show(intensity: Float) { renderer.intensity = intensity; view.isPaused = false; window.orderFrontRegardless() }
    func hide() { window.orderOut(nil); view.isPaused = true; renderer.capture.stop(); renderer.clear(animated:false) }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private var overlays: [Overlay] = []
    private let weather = WeatherService()
    private var mode = "auto"
    private var weatherIntensity: Float = 0
    private var weatherLabel = L10n.text("現在地の天気を準備中", "Preparing weather for current location")
    private var captureMessage: String?
    private var strength: Float = 1.4
    private var randomStrength = false
    private var randomStrengthValue: Float = 1.4
    private var randomStrengthIntervalIndex = 2
    private var randomStrengthTimer: Timer?
    private var frameRate: Int = 30
    private var renderQuality: RainRenderQuality = .high
    private var refraction = true
    private var chromaticAberration: Float = 1
    private var dropScale: Float = 1
    private var wipeAnimation: WipeAnimation = .drain
    private let dropScales: [Float] = [1,1.25,1.5,1.75,2,2.5]
    private var suspended = false
    private var activeIntensity: Float = 0
    private var resetOnMissionControl = false
    private var missionControlSuppressed = false
    private var missionControlMonitor: Timer?
    private var missionControlEvidence = 0
    private var missionControlExitEvidence = 0
    private var exclusionMonitor: Timer?
    private var excludedAppBundleIDs: Set<String> = []
    private var statusLabel: NSMenuItem!
    private var rainStatusLabel: NSMenuItem!
    private var hotKey: GlobalHotKey?
    private var wipeHotKey: GlobalHotKey?
    private var stopToggleHotKey: GlobalHotKey?
    private var wipeShortcut: HotKeyShortcut?
    private var stopToggleShortcut: HotKeyShortcut?
    private var wipeHotKeyID: UInt32 = 2
    private var stopToggleHotKeyID: UInt32 = 4
    private var modeBeforeStop = "auto"
    private var allDisplays = true
    private var selectedDisplayIDs: Set<String> = []
    private var previewWindow: NSWindow?
    private var previewRenderer: RainRenderer?
    private var observers: [NSObjectProtocol] = []
    private var locationSearchTask: Task<Void,Never>?
    private var dryingTimer: Timer?
    private var isDrying = false
    private var settingsController: SettingsWindowController?
    private var settingsPreviewMode = false
    private var effectiveStrength: Float { randomStrength ? randomStrengthValue : strength }

    var isSettingsPreview: Bool { settingsPreviewMode }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadPersistedSettings()
        if CommandLine.arguments.contains("--settings-preview") || CommandLine.arguments.contains("--settings-smoke-test") {
            settingsPreviewMode = true
            openSettings()
            if CommandLine.arguments.contains("--settings-smoke-test") {
                DispatchQueue.main.async { [weak self] in self?.settingsController?.runSmokeTest() }
            }
            return
        }
        if CommandLine.arguments.contains("--settings-state-test") {
            settingsPreviewMode = true
            runSettingsStateTest()
            return
        }
        if CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--preview") {
            preview(); return
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.noa.RainGlass").count > 1 {
            NSApp.terminate(nil); return
        }
        status = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName:"cloud.rain",accessibilityDescription:"Rainy Screen")
        let menu = NSMenu(); menu.delegate = self; status.menu = menu
        let main = NSMenu()
        let appItem = NSMenuItem(title:"Rainy Screen",action:nil,keyEquivalent:"")
        let appMenu = NSMenu(); appMenu.delegate = self
        menuWillOpen(appMenu)
        appItem.submenu = appMenu; main.addItem(appItem); NSApp.mainMenu = main
        hotKey = GlobalHotKey { [weak self] in self?.stopMode() }
        if let wipeShortcut {
            wipeHotKey = GlobalHotKey(shortcut:wipeShortcut,id:wipeHotKeyID) { [weak self] in self?.dry() }
        }
        if let stopToggleShortcut {
            let candidate = GlobalHotKey(shortcut:stopToggleShortcut,id:stopToggleHotKeyID) { [weak self] in self?.toggleStopMode() }
            if candidate.isRegistered { stopToggleHotKey = candidate }
        }
        weather.onUpdate = { [weak self] intensity,label in
            guard let self else { return }
            self.weatherIntensity = intensity; self.weatherLabel = label; self.apply()
        }
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.rebuild(); self?.postStateChange() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.activeSpaceDidChangeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.checkMissionControlState() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didLaunchApplicationNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.updateExcludedAppWindows(); self?.postStateChange() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didTerminateApplicationNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.updateExcludedAppWindows(); self?.postStateChange() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.updateExcludedAppWindows(); self?.postStateChange() }
        })
        for name in [NSWorkspace.willSleepNotification,NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.suspended = true; self?.apply() }
            })
        }
        for name in [NSWorkspace.didWakeNotification,NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.suspended = false; self?.rebuild(); self?.weather.refresh() }
            })
        }
        rebuild()
        startMissionControlMonitor()
        startExclusionMonitor()
        startRandomStrengthTimer()
        if mode == "auto" { weather.start() }
        if !UserDefaults.standard.bool(forKey:"welcomed") {
            UserDefaults.standard.set(true,forKey:"welcomed")
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { [weak self] in self?.showHelp() }
        }
    }
    private func loadPersistedSettings() {
        UserDefaults.standard.register(defaults:["refraction":true,"dropScale":Float(1),"frameRate":30,"renderQuality":RainRenderQuality.high.rawValue,"chromaticAberration":Float(1),
                                                  "resetOnMissionControl":false,"excludedAppBundleIDs":[String](),
                                                  "randomStrength":false,"randomStrengthInterval":2,
                                                  "wipeAnimation":WipeAnimation.drain.rawValue,
                                                  "languagePreference": L10n.Preference.system.rawValue])
        strength = UserDefaults.standard.object(forKey:"strength") as? Float ?? 1.4
        randomStrength = UserDefaults.standard.bool(forKey:"randomStrength")
        let savedRandomInterval = UserDefaults.standard.integer(forKey:"randomStrengthInterval")
        randomStrengthIntervalIndex = randomStrengthIntervals.indices.contains(savedRandomInterval) ? savedRandomInterval : 2
        randomStrengthValue = randomStrength ? nextRandomStrength() : strength
        refraction = UserDefaults.standard.bool(forKey:"refraction")
        let savedAberration = UserDefaults.standard.float(forKey:"chromaticAberration")
        chromaticAberration = ChromaticAberration.levels.contains(savedAberration) ? savedAberration : 1
        let savedFrameRate = UserDefaults.standard.integer(forKey:"frameRate")
        frameRate = supportedFrameRates.contains(savedFrameRate) ? savedFrameRate : 30
        let savedQuality = UserDefaults.standard.integer(forKey:"renderQuality")
        renderQuality = RainRenderQuality(rawValue:savedQuality) ?? .high
        let savedScale = UserDefaults.standard.float(forKey:"dropScale")
        dropScale = dropScales.contains(savedScale) ? savedScale : 1
        wipeAnimation = WipeAnimation(rawValue: UserDefaults.standard.integer(forKey:"wipeAnimation")) ?? .drain
        resetOnMissionControl = UserDefaults.standard.bool(forKey:"resetOnMissionControl")
        excludedAppBundleIDs = Set(UserDefaults.standard.stringArray(forKey:"excludedAppBundleIDs") ?? [])
        allDisplays = UserDefaults.standard.object(forKey:"allDisplays") as? Bool ?? true
        selectedDisplayIDs = Set(UserDefaults.standard.stringArray(forKey:"selectedDisplayIDs") ?? [])
        if let data = UserDefaults.standard.data(forKey:"wipeShortcut") {
            wipeShortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from:data)
        }
        if let data = UserDefaults.standard.data(forKey:"stopToggleShortcut") {
            stopToggleShortcut = try? JSONDecoder().decode(HotKeyShortcut.self, from:data)
        }
        let savedMode = UserDefaults.standard.string(forKey:"mode") ?? "auto"
        let savedModeBeforeStop = UserDefaults.standard.string(forKey:"modeBeforeStop")
        modeBeforeStop = ["auto", "demo"].contains(savedModeBeforeStop) ? savedModeBeforeStop! : (savedMode == "demo" ? "demo" : "auto")
        mode = savedMode
        if mode == "demo" && settingsPreviewMode { mode = "demo" }
        if mode == "demo" && !settingsPreviewMode { mode = "auto" }
    }

    private func persist(_ value: Any?, key: String) {
        guard !settingsPreviewMode else { return }
        UserDefaults.standard.set(value, forKey:key)
    }

    private func postStateChange() {
        NotificationCenter.default.post(name:.rainyScreenStateDidChange, object:self)
    }

    private func rebuild() {
        dryingTimer?.invalidate(); dryingTimer = nil; isDrying = false
        overlays.forEach {$0.hide()}; overlays.removeAll(); activeIntensity = 0
        missionControlEvidence = 0; missionControlExitEvidence = 0
        missionControlSuppressed = false
        captureMessage = nil
        guard let device = MTLCreateSystemDefaultDevice() else { showError(L10n.text("Metal対応GPUがありません", "No Metal-capable GPU is available.")); return }
        do {
            for screen in NSScreen.screens where allDisplays || selectedDisplayIDs.contains(displayIdentity(screen)) {
                let overlay = try Overlay(screen:screen,device:device,framesPerSecond:frameRate)
                overlay.renderer.capture.onError = { [weak self] message in
                    self?.captureMessage = L10n.text("画面取得: \(message)", "Screen capture: \(message)"); self?.updateTooltip()
                }
                overlay.renderer.dropScale = dropScale
                overlay.renderer.renderQuality = renderQuality
                overlay.renderer.chromaticAberration = chromaticAberration
                overlay.renderer.wipeAnimation = wipeAnimation
                overlay.renderer.mistMode = abs(effectiveStrength-mistStrength) < 0.01
                overlays.append(overlay)
            }
            apply()
            updateExcludedAppWindows()
        } catch { showError(error.localizedDescription) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let menu = status?.menu else { return false }
        menu.popUp(positioning:nil,at:NSEvent.mouseLocation,in:nil)
        return false
    }
    private func apply() {
        if suspended || mode == "off" {
            missionControlSuppressed = false
            finishDrying()
            activeIntensity = 0
            for overlay in overlays { overlay.hide() }
            updateTooltip()
            return
        }
        if missionControlSuppressed {
            dryingTimer?.invalidate(); dryingTimer = nil; isDrying = false
            activeIntensity = 0
            for overlay in overlays { overlay.show(intensity:0) }
            updateTooltip()
            return
        }
        let target: Float = mode == "demo" ? effectiveStrength : weatherIntensity*effectiveStrength
        let wasVisible = activeIntensity > 0 || isDrying
        if target > 0 {
            dryingTimer?.invalidate(); dryingTimer = nil; isDrying = false
            activeIntensity = target
            for overlay in overlays {
                overlay.renderer.mistMode = abs(effectiveStrength-mistStrength) < 0.01
                overlay.show(intensity:target)
                if !wasVisible && refraction && CGPreflightScreenCaptureAccess() { startCapture(overlay) }
            }
        } else if mode == "auto", !suspended, wasVisible {
            activeIntensity = 0
            if !isDrying {
                isDrying = true
                for overlay in overlays { overlay.show(intensity:0) }
                dryingTimer?.invalidate()
                dryingTimer = Timer.scheduledTimer(withTimeInterval:18, repeats:false) { [weak self] _ in
                    Task { @MainActor in self?.finishDrying() }
                }
            } else {
                for overlay in overlays { overlay.show(intensity:0) }
            }
        } else {
            finishDrying()
            activeIntensity = 0
            for overlay in overlays { overlay.hide() }
        }
        updateTooltip()
    }
    private func finishDrying() {
        dryingTimer?.invalidate(); dryingTimer = nil
        guard isDrying else { return }
        isDrying = false
        for overlay in overlays { overlay.hide() }
        updateTooltip()
    }
    private func startMissionControlMonitor() {
        missionControlMonitor?.invalidate()
        missionControlMonitor = nil
        guard resetOnMissionControl else { return }
        missionControlMonitor = Timer.scheduledTimer(withTimeInterval:0.15,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.checkMissionControlState() }
        }
    }
    private func startExclusionMonitor() {
        exclusionMonitor?.invalidate()
        exclusionMonitor = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.updateExcludedAppWindows() }
        }
    }
    private func updateExcludedAppWindows() {
        guard !overlays.isEmpty else { return }
        guard !excludedAppBundleIDs.isEmpty else {
            for overlay in overlays { overlay.renderer.exclusionRects = [] }
            return
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] else { return }
        var bundleIDsByPID: [Int32:String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier else { continue }
            bundleIDsByPID[app.processIdentifier] = bundleID
        }
        var rectsByDisplay: [CGDirectDisplayID:[SIMD4<Float>]] = [:]
        for info in windows {
            guard let pid = (info["kCGWindowOwnerPID"] as? NSNumber)?.int32Value,
                  let bundleID = bundleIDsByPID[pid], excludedAppBundleIDs.contains(bundleID),
                  bundleID != Bundle.main.bundleIdentifier,
                  let windowRect = cgWindowBounds(info), windowRect.width > 2, windowRect.height > 2 else { continue }
            for overlay in overlays {
                let displayBounds = CGDisplayBounds(overlay.displayID)
                let intersection = windowRect.intersection(displayBounds)
                guard !intersection.isNull, intersection.width > 2, intersection.height > 2 else { continue }
                let viewWidth = max(1,overlay.view.bounds.width)
                let viewHeight = max(1,overlay.view.bounds.height)
                let scaleX = viewWidth/max(1,displayBounds.width)
                let scaleY = viewHeight/max(1,displayBounds.height)
                let x0 = max(0,min(viewWidth,(intersection.minX-displayBounds.minX)*scaleX))
                let x1 = max(0,min(viewWidth,(intersection.maxX-displayBounds.minX)*scaleX))
                let top0 = max(0,min(displayBounds.height,(intersection.minY-displayBounds.minY)))
                let top1 = max(0,min(displayBounds.height,(intersection.maxY-displayBounds.minY)))
                // CGWindowBounds and the Metal full-screen UV both use a
                // top-origin coordinate here, so do not flip the Y axis.
                let y0 = max(0,min(viewHeight,top0*scaleY))
                let y1 = max(0,min(viewHeight,top1*scaleY))
                guard x1-x0 > 2, y1-y0 > 2 else { continue }
                rectsByDisplay[overlay.displayID,default:[]].append(SIMD4(Float(x0),Float(y0),Float(x1),Float(y1)))
            }
        }
        for overlay in overlays {
            overlay.renderer.exclusionRects = Array((rectsByDisplay[overlay.displayID] ?? []).prefix(16))
        }
    }
    private func cgWindowBounds(_ info: [String:Any]) -> CGRect? {
        guard let bounds = info["kCGWindowBounds"] as? [String:Any],
              let x = (bounds["X"] as? NSNumber)?.doubleValue,
              let y = (bounds["Y"] as? NSNumber)?.doubleValue,
              let width = (bounds["Width"] as? NSNumber)?.doubleValue,
              let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return nil }
        return CGRect(x:x,y:y,width:width,height:height)
    }
    private func checkMissionControlState() {
        guard resetOnMissionControl, !suspended, !overlays.isEmpty else { return }
        let visible = overlays.contains { $0.window.isVisible && $0.window.occlusionState.contains(.visible) }
        // Mission Control is rendered by Dock. During the overview it exposes
        // a full-screen, non-shareable layer-18 window at the main display's
        // origin. This is the reliable signal when the overlay itself remains
        // visible because it joins all Spaces.
        let missionControlWindow = isMissionControlWindowPresent()
            || isMissionControlProcessActive()
        let missionControlActive = missionControlWindow || !visible
        if missionControlActive {
            missionControlExitEvidence = 0
            missionControlEvidence = min(missionControlEvidence + 1, 4)
        } else {
            missionControlEvidence = 0
            missionControlExitEvidence = min(missionControlExitEvidence + 1, 4)
        }
        if missionControlSuppressed {
            if !missionControlActive && missionControlExitEvidence >= 2 {
                missionControlSuppressed = false
                for overlay in overlays { overlay.hide() }
                apply()
            }
        } else if (activeIntensity > 0 || isDrying) && missionControlEvidence >= 2 {
            missionControlSuppressed = true
            dryingTimer?.invalidate(); dryingTimer = nil; isDrying = false
            activeIntensity = 0
            for overlay in overlays {
                overlay.renderer.capture.stop()
                overlay.renderer.clear(animated:false)
                overlay.show(intensity:0)
            }
            updateTooltip()
        }
    }
    private func isMissionControlWindowPresent() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String:Any]] else {
            return false
        }
        return windows.contains { info in
            guard info["kCGWindowOwnerName"] as? String == "Dock",
                  (info["kCGWindowLayer"] as? NSNumber)?.intValue == 18,
                  (info["kCGWindowSharingState"] as? NSNumber)?.intValue == 0,
                  let bounds = info["kCGWindowBounds"] as? [String:Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue else { return false }
            return abs(x) < 1 && abs(y) < 1
        }
    }
    private func isMissionControlProcessActive() -> Bool {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.exposelauncher" {
            return true
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.exposelauncher")
            .contains { $0.isActive && !$0.isTerminated }
    }
    private func startCapture(_ overlay: Overlay) {
        Task { await overlay.renderer.capture.start(displayID:overlay.displayID,size:overlay.view.drawableSize) }
    }
    private func updateTooltip() {
        let label = missionControlSuppressed ? L10n.text("Mission Control中 · 雨をリセット中", "Reset while Mission Control is active")
            : (mode == "demo" ? L10n.text("雨の試運転", "Rainy mode") : mode == "off" ? L10n.text("停止中", "Stopped") : weatherLabel)
        status?.button?.toolTip = "Rainy Screen — \(label)"
        statusLabel?.title = L10n.text("状態: \(isModeRunning ? "稼働中" : "停止中")", "Status: \(isModeRunning ? "Running" : "Stopped")")
        rainStatusLabel?.title = L10n.text("雨: \(isActuallyRendering ? "描画中" : "未描画")", "Rain: \(isActuallyRendering ? "Rendering" : "Not Rendering")")
        postStateChange()
    }

    private var isActuallyRendering: Bool {
        guard !suspended, !missionControlSuppressed, (activeIntensity > 0 || isDrying) else { return false }
        return overlays.contains { $0.window.isVisible && !$0.view.isPaused }
    }

    private var isModeRunning: Bool { mode != "off" }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.0"
        menu.addItem(NSMenuItem(title:"Rainy Screen \(version)", action:nil, keyEquivalent:""))
        menu.addItem(.separator())
        statusLabel = NSMenuItem(title:L10n.text("状態: \(isModeRunning ? "稼働中" : "停止中")", "Status: \(isModeRunning ? "Running" : "Stopped")"), action:nil, keyEquivalent:"")
        rainStatusLabel = NSMenuItem(title:L10n.text("雨: \(isActuallyRendering ? "描画中" : "未描画")", "Rain: \(isActuallyRendering ? "Rendering" : "Not Rendering")"), action:nil, keyEquivalent:"")
        menu.addItem(statusLabel)
        menu.addItem(rainStatusLabel)
        menu.addItem(.separator())
        item(menu,L10n.text("ウェザーモード", "Weather Mode"),#selector(autoMode),checked:mode == "auto")
        item(menu,L10n.text("レイニーモード", "Rainy Mode"),#selector(demoMode),checked:mode == "demo")
        item(menu,L10n.text("停止", "Stop"),#selector(stopMode),key:".",checked:mode == "off")
        menu.addItem(.separator())
        let intensity = NSMenuItem(title:L10n.text("雨の強さ [\(currentStrengthLabel)]", "Rain Intensity [\(currentStrengthLabel)]"), action:nil, keyEquivalent:"")
        let intensityMenu = NSMenu()
        for option in rainStrengthOptions {
            let label = L10n.text(option.label, strengthEnglishLabel(option.value))
            let child = item(intensityMenu,label,#selector(setStrength(_:)),checked:!randomStrength && abs(strength-option.value)<0.01)
            child.representedObject = option.value
        }
        let random = item(intensityMenu,L10n.text("ランダム", "Random"),#selector(enableRandomStrength),checked:randomStrength)
        random.toolTip = L10n.text("設定で切替間隔を変更できます", "Change the interval in Settings")
        intensity.submenu = intensityMenu; menu.addItem(intensity)
        let size = NSMenuItem(title:L10n.text("雨粒のサイズ [\(dropScaleLabel)]", "Raindrop Size [\(dropScaleLabel)]"), action:nil, keyEquivalent:"")
        let sizeMenu = NSMenu()
        for value in dropScales {
            let child = item(sizeMenu,dropScaleDisplayLabel(value),#selector(setDropScale(_:)),checked:dropScale == value)
            child.representedObject = value
        }
        size.submenu = sizeMenu; menu.addItem(size)
        let fps = NSMenuItem(title:L10n.text("描画FPS [\(frameRate) FPS]", "Frame Rate [\(frameRate) FPS]"), action:nil, keyEquivalent:"")
        let fpsMenu = NSMenu()
        for value in supportedFrameRates {
            let child = item(fpsMenu,"\(value) FPS",#selector(setFrameRate(_:)),checked:frameRate == value)
            child.representedObject = value
        }
        fps.submenu = fpsMenu; menu.addItem(fps)
        menu.addItem(.separator())
        item(menu,L10n.text("窓を一度拭き上げる", "Wipe Window"),#selector(dry))
        item(menu,L10n.text("天気を取得・更新", "Refresh Weather"),#selector(refresh))
        menu.addItem(.separator())
        item(menu,L10n.text("設定…", "Settings…"),#selector(openSettings))
        menu.addItem(.separator())
        item(menu,L10n.text("終了", "Quit"),#selector(quit),key:"q")
    }

    private var currentStrengthLabel: String {
        if randomStrength { return L10n.text("ランダム", "Random") }
        if let option = rainStrengthOptions.first(where: { abs($0.value - strength) < 0.01 }) {
            return L10n.text(option.label, strengthEnglishLabel(option.value))
        }
        return String(format:"%.2f", strength)
    }

    private var dropScaleLabel: String { String(format:"%.3gx", dropScale) }

    private func dropScaleDisplayLabel(_ value: Float) -> String {
        String(format: "%.3gx", value)
    }

    private func strengthEnglishLabel(_ value: Float) -> String {
        switch value {
        case 0.35: return "Mist"
        case 0.8: return "Light"
        case 1.4: return "Medium"
        case 2.4: return "Strong"
        case 3.8: return "Heavy"
        default: return "Downpour"
        }
    }

    @objc func openSettings() {
        let shouldCenter = settingsController == nil
        if settingsController == nil {
            settingsController = SettingsWindowController(app: self, preview: settingsPreviewMode)
        }
        settingsController?.showWindow(nil)
        if shouldCenter { settingsController?.window?.center() }
        settingsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }

    func refreshSettingsWindow() {
        settingsController?.refreshFromApp()
    }

    private func displayIdentity(_ screen: NSScreen) -> String {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            return CFUUIDCreateString(nil,uuid) as String
        }
        return "display-\(id)"
    }
    private func saveDisplaySelection() {
        persist(allDisplays, key:"allDisplays")
        persist(selectedDisplayIDs.sorted(), key:"selectedDisplayIDs")
        rebuild()
        postStateChange()
    }
    @objc private func selectAllDisplays() {
        allDisplays = true
        saveDisplaySelection()
    }
    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let identity = sender.representedObject as? String else { return }
        if allDisplays {
            selectedDisplayIDs = Set(NSScreen.screens.map { displayIdentity($0) })
            allDisplays = false
        }
        if selectedDisplayIDs.contains(identity) { selectedDisplayIDs.remove(identity) }
        else { selectedDisplayIDs.insert(identity) }
        saveDisplaySelection()
    }
    @objc private func configureWipeShortcut() {
        let alert = NSAlert()
        alert.messageText = L10n.text("拭き上げのグローバルショートカット", "Global wipe shortcut")
        alert.informativeText = L10n.text("入力欄で登録するキーを押してください。Control・Option・Commandのいずれかを含めます。ほかのアプリを操作中も、対象ディスプレイの窓を拭き上げます。", "Press the shortcut in the field. Include Control, Option, or Command. The selected displays are wiped while another app is active.")
        let recorder = ShortcutRecorder(frame:NSRect(x:0,y:0,width:440,height:30))
        recorder.isEditable = false
        recorder.stringValue = L10n.text("ここをクリックしてキーを押してください", "Click here and press a shortcut")
        alert.accessoryView = recorder
        alert.addButton(withTitle:L10n.text("登録", "Register"))
        alert.addButton(withTitle:L10n.text("キャンセル", "Cancel"))
        alert.addButton(withTitle:L10n.text("登録を解除", "Clear"))
        alert.buttons[0].isEnabled = false
        recorder.onChange = { [weak alert, weak recorder] in
            alert?.buttons[0].isEnabled = recorder?.shortcut != nil
        }
        alert.window.initialFirstResponder = recorder
        NSApp.activate(ignoringOtherApps:true)
        let response = alert.runModal()
        if response == .alertThirdButtonReturn {
            wipeHotKey = nil; wipeShortcut = nil
            if !settingsPreviewMode { UserDefaults.standard.removeObject(forKey:"wipeShortcut") }
        } else if response == .alertFirstButtonReturn, let shortcut = recorder.shortcut {
            if shortcut == wipeShortcut && wipeHotKey?.isRegistered == true { return }
            // Register first so a conflict leaves the previous shortcut working.
            let nextID = wipeHotKeyID == 2 ? UInt32(3) : UInt32(2)
            let candidate = GlobalHotKey(shortcut:shortcut,id:nextID) { [weak self] in self?.dry() }
            guard candidate.isRegistered else {
                showError(L10n.text("このショートカットは登録できません。ほかのアプリや停止キーで使用中の可能性があります。別の組み合わせを指定してください。以前の設定は保持しています。", "This shortcut cannot be registered. It may be used by another app or the fixed stop shortcut. Choose another combination. The previous setting was kept."))
                return
            }
            wipeHotKey = candidate; wipeHotKeyID = nextID; wipeShortcut = shortcut
            if !settingsPreviewMode { UserDefaults.standard.set(try? JSONEncoder().encode(shortcut),forKey:"wipeShortcut") }
        }
    }
    private func runningApplicationsForAllowlist() -> [(String,String)] {
        let ownBundleID = Bundle.main.bundleIdentifier
        var byBundleID: [String:String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard !app.isTerminated, app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier, bundleID != ownBundleID else { continue }
            byBundleID[bundleID] = app.localizedName ?? bundleID
        }
        return byBundleID.map { ($0.key,$0.value) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
    @objc private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("雨を除外するアプリを選択", "Choose an app to exclude")
        panel.message = L10n.text("追加したアプリのウィンドウには雨が表示されません。", "Rain will be hidden from windows of the selected app.")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        NSApp.activate(ignoringOtherApps:true)
        guard panel.runModal() == .OK else { return }
        var added = false
        for url in panel.urls {
            guard let bundleID = Bundle(url:url)?.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier else { continue }
            if excludedAppBundleIDs.insert(bundleID).inserted { added = true }
        }
        guard added else { return }
        saveExcludedApps()
        updateExcludedAppWindows()
    }
    @objc private func toggleExcludedApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String, !bundleID.isEmpty else { return }
        if excludedAppBundleIDs.contains(bundleID) { excludedAppBundleIDs.remove(bundleID) }
        else { excludedAppBundleIDs.insert(bundleID) }
        saveExcludedApps()
        updateExcludedAppWindows()
    }
    @objc private func clearExcludedApps() {
        excludedAppBundleIDs.removeAll()
        if !settingsPreviewMode { UserDefaults.standard.removeObject(forKey:"excludedAppBundleIDs") }
        updateExcludedAppWindows()
        postStateChange()
    }
    private func saveExcludedApps() {
        persist(Array(excludedAppBundleIDs).sorted(), key:"excludedAppBundleIDs")
        postStateChange()
    }
    @discardableResult private func item(_ menu:NSMenu,_ title:String,_ action:Selector,key:String = "",checked:Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title:title,action:action,keyEquivalent:key); i.target = self; i.state = checked ? .on : .off; menu.addItem(i); return i
    }
    private func rememberModeBeforeStop(_ value: String) {
        guard value == "auto" || value == "demo" else { return }
        modeBeforeStop = value
        persist(value, key:"modeBeforeStop")
    }
    @objc private func autoMode() {
        if mode != "off" { rememberModeBeforeStop("auto") }
        mode = "auto"; saveMode(); weather.start(); apply()
    }
    @objc private func demoMode() {
        if mode != "off" { rememberModeBeforeStop("demo") }
        mode = "demo"; weather.stop(); weatherLabel = L10n.text("試運転中 · 天気に関係なく雨を表示", "Rainy mode · rain is independent of weather"); apply()
    }
    @objc private func stopMode() {
        if mode == "auto" || mode == "demo" { rememberModeBeforeStop(mode) }
        mode = "off"; saveMode(); weather.stop(); weatherLabel = L10n.text("停止中", "Stopped"); apply()
    }
    @objc private func toggleStopMode() {
        if mode == "off" {
            if modeBeforeStop == "demo" { demoMode() } else { autoMode() }
        } else {
            stopMode()
        }
    }
    @objc private func useCurrentLocation() {
        weather.useCurrentLocation()
        weatherLabel = L10n.text("現在地の天気を準備中", "Preparing weather for current location")
        if mode == "auto" { weather.refresh() }
        else { updateTooltip() }
    }
    @objc private func selectLocation() {
        let alert = NSAlert()
        alert.messageText = L10n.text("天気の場所を指定", "Choose a weather location")
        alert.informativeText = L10n.text("地名を入力して検索してください。指定地点は次回起動時も使用します。", "Search for a place. The selected location will be used next time too.")
        let field = NSTextField(string: weather.usesManualLocation ? weather.locationTitle : "")
        field.placeholderString = L10n.text("例: 東京、大阪、札幌", "Example: Tokyo, Osaka, Sapporo")
        field.frame = NSRect(x:0,y:0,width:360,height:24)
        alert.accessoryView = field
        alert.addButton(withTitle:L10n.text("検索", "Search"))
        alert.addButton(withTitle:L10n.text("キャンセル", "Cancel"))
        NSApp.activate(ignoringOtherApps:true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        locationSearchTask?.cancel()
        weatherLabel = L10n.text("地点を検索中…", "Searching for locations…")
        updateTooltip()
        locationSearchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let results = try await self.weather.searchLocations(query)
                guard !Task.isCancelled else { return }
                self.presentLocationChoices(results)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.showError(L10n.text("地点検索に失敗しました。ネットワーク接続を確認してください。", "Could not search for locations. Check your network connection."))
            }
        }
    }
    private func presentLocationChoices(_ locations: [WeatherLocation]) {
        guard !locations.isEmpty else {
            showError(L10n.text("該当する地点が見つかりませんでした。別の地名で検索してください。", "No matching locations were found. Try another place name."))
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("天気に使う地点を選択", "Select a weather location")
        alert.informativeText = L10n.text("候補から1つ選択してください。", "Choose one location from the results.")
        let popup = NSPopUpButton(frame:NSRect(x:0,y:0,width:420,height:28),pullsDown:false)
        popup.addItems(withTitles:locations.map { $0.name })
        alert.accessoryView = popup
        alert.addButton(withTitle:L10n.text("この場所を使用", "Use this location"))
        alert.addButton(withTitle:L10n.text("キャンセル", "Cancel"))
        NSApp.activate(ignoringOtherApps:true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = popup.indexOfSelectedItem
        guard locations.indices.contains(index) else { return }
        weather.setManualLocation(locations[index])
        weatherLabel = L10n.text("\(locations[index].name)の天気を準備中", "Preparing weather for \(locations[index].name)")
        if mode == "auto" { weather.refresh() }
        else { updateTooltip() }
    }
    private func saveMode() { persist(mode, key:"mode"); postStateChange() }
    @objc private func dry() { overlays.forEach {$0.renderer.clear(animated:true)} }
    @objc private func refresh() {
        guard !settingsPreviewMode else { return }
        weather.refreshOnce()
        refreshSettingsWindow()
    }
    private func nextRandomStrength() -> Float {
        let candidates = rainStrengthOptions.map { $0.value }
        let available = candidates.filter { abs($0-randomStrengthValue) >= 0.01 }
        return available.randomElement() ?? candidates.first ?? 1.4
    }
    private func startRandomStrengthTimer() {
        randomStrengthTimer?.invalidate(); randomStrengthTimer = nil
        guard randomStrength, randomStrengthIntervals.indices.contains(randomStrengthIntervalIndex) else { return }
        let seconds = randomStrengthIntervals[randomStrengthIntervalIndex].seconds
        randomStrengthTimer = Timer.scheduledTimer(withTimeInterval:seconds,repeats:false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.randomStrength else { return }
                self.randomStrengthValue = self.nextRandomStrength()
                self.apply()
                self.startRandomStrengthTimer()
            }
        }
    }
    @objc private func enableRandomStrength() {
        guard !randomStrength else { return }
        randomStrength = true
        randomStrengthValue = nextRandomStrength()
        persist(true, key:"randomStrength")
        startRandomStrengthTimer()
        apply()
    }
    @objc private func setRandomStrengthInterval(_ sender:NSMenuItem) {
        guard let index = sender.representedObject as? Int,
              randomStrengthIntervals.indices.contains(index) else { return }
        randomStrengthIntervalIndex = index
        persist(index, key:"randomStrengthInterval")
        startRandomStrengthTimer()
        updateTooltip()
    }
    @objc private func setStrength(_ sender:NSMenuItem) {
        guard let value = sender.representedObject as? Float,
              rainStrengthOptions.contains(where: { abs($0.value-value) < 0.01 }) else { return }
        strength = value
        randomStrength = false
        randomStrengthValue = value
        randomStrengthTimer?.invalidate(); randomStrengthTimer = nil
        persist(strength, key:"strength")
        persist(false, key:"randomStrength")
        apply()
    }
    @objc private func setDropScale(_ sender:NSMenuItem) {
        guard let value = sender.representedObject as? Float, dropScales.contains(value) else { return }
        dropScale = value
        persist(value, key:"dropScale")
        for overlay in overlays {
            overlay.renderer.dropScale = value
            overlay.renderer.clear(animated:false)
        }
        postStateChange()
    }
    @objc private func setFrameRate(_ sender:NSMenuItem) {
        guard let value = sender.representedObject as? Int, supportedFrameRates.contains(value) else { return }
        frameRate = value
        persist(value, key:"frameRate")
        for overlay in overlays { overlay.view.preferredFramesPerSecond = value }
        updateTooltip()
    }
    @objc private func toggleRefraction() {
        refraction.toggle()
        persist(refraction, key:"refraction")
        captureMessage = nil
        if refraction && !CGPreflightScreenCaptureAccess() { requestCapturePermission(); return }
        for overlay in overlays {
            if refraction && activeIntensity > 0 { startCapture(overlay) }
            else { overlay.renderer.capture.stop() }
        }
    }
    @objc private func toggleMissionControlReset() {
        resetOnMissionControl.toggle()
        persist(resetOnMissionControl, key:"resetOnMissionControl")
        startMissionControlMonitor()
        if !resetOnMissionControl && missionControlSuppressed {
            missionControlSuppressed = false
            for overlay in overlays { overlay.hide() }
        }
        apply()
    }
    @objc private func requestCapturePermission() {
        let granted = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        if granted {
            captureMessage = nil
            for overlay in overlays where refraction && activeIntensity > 0 { startCapture(overlay) }
        } else {
            captureMessage = L10n.text("屈折はオン · 画面収録の許可待ち", "Refraction is on · waiting for Screen Recording permission")
            showError(L10n.text("画面収録でRainy Screenを許可してください。屈折の設定はオンのまま保持します。設定がすでにオンでも、更新直後はアプリを終了して一覧から再追加する必要がある場合があります。", "Allow Rainy Screen in Screen Recording. Refraction remains enabled. If it is already enabled, you may need to quit and add the app again after an update."))
        }
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { showError(L10n.text("ログイン項目の変更に失敗: \(error.localizedDescription)", "Could not change the login item: \(error.localizedDescription)")) }
    }
    @objc private func locationSettings() { openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") }
    @objc private func captureSettings() { openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") }
    @objc private func attribution() { openURL("https://open-meteo.com/") }
    private func openURL(_ value:String) { if let url = URL(string:value) { NSWorkspace.shared.open(url) } }
    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Rainy Screen — \(L10n.text("デスクトップを雨の窓に", "A rainy window for your desktop"))"
        alert.informativeText = L10n.text("設定ウインドウまたはメニューバーのRainy Screenから操作できます。\n\n・Weather Mode: 位置情報または指定地点の天気に連動します。\n・Rainy Mode: 晴れていても雨を表示します。\n・雨の強さ: 霧雨から豪雨まで選択できます。ランダム切替も可能です。\n・カーソルを動かすと、その軌跡が拭かれます。\n・背景の屈折・ぼかしには画面収録の許可が必要です。画面は保存・送信しません。\n・雨が止んだ後は、残った水滴・水路・曇りが徐々に乾きます。\n\n天気データはOpen-Meteoを使用します。", "Use Rainy Screen from the Settings window or menu bar.\n\n• Weather Mode follows weather at your current or selected location.\n• Rainy Mode displays rain even when it is clear.\n• Choose an intensity from mist to downpour, or switch randomly over time.\n• Move the cursor to wipe the window.\n• Screen Recording permission is required for background refraction and blur. The screen is not saved or uploaded.\n• Remaining droplets and fog dry gradually after rain stops.\n\nWeather data is provided by Open-Meteo.")
        alert.addButton(withTitle:L10n.text("閉じる", "Close")); NSApp.activate(ignoringOtherApps:true); alert.runModal()
    }
    private func showError(_ message:String) {
        let alert = NSAlert(); alert.messageText = "Rainy Screen"; alert.informativeText = message
        NSApp.activate(ignoringOtherApps:true); alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification:Notification) {
        weather.stop()
        randomStrengthTimer?.invalidate()
        missionControlMonitor?.invalidate()
        exclusionMonitor?.invalidate()
        overlays.forEach {$0.hide()}
    }

    private func preview() {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain:"Metal",code:1) }
            let frame = NSRect(x:200,y:160,width:1000,height:680)
            let window = NSWindow(contentRect:frame,styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title = L10n.text("Rainy Screen — 描画プレビュー", "Rainy Screen — Render Preview"); window.isReleasedWhenClosed = false
            let view = MTKView(frame:NSRect(origin:.zero,size:frame.size),device:device)
            view.colorPixelFormat = .bgra8Unorm; view.preferredFramesPerSecond = 30
            view.framebufferOnly = false
            view.clearColor = MTLClearColorMake(0.12,0.18,0.24,1)
            let renderer = try RainRenderer(view:view,screenFrame:frame)
            renderer.previewTexture = try PreviewScene.texture(device:device,dark:CommandLine.arguments.contains("--dark-preview"))
            if let index = CommandLine.arguments.firstIndex(of:"--wipe-animation"), index+1 < CommandLine.arguments.count {
                renderer.wipeAnimation = CommandLine.arguments[index+1].lowercased() == "vertical" ? .vertical : .drain
            }
            if let index = CommandLine.arguments.firstIndex(of:"--drop-scale"), index+1 < CommandLine.arguments.count,
               let scale = Float(CommandLine.arguments[index+1]), dropScales.contains(scale) { renderer.dropScale = scale }
            renderer.intensity = 1.4
            if let index = CommandLine.arguments.firstIndex(of:"--intensity"), index+1 < CommandLine.arguments.count,
               let value = Float(CommandLine.arguments[index+1]), value > 0, value <= 8.4 { renderer.intensity = value }
            renderer.preparePreview()
            if let index = CommandLine.arguments.firstIndex(of:"--chromatic-aberration"), index+1 < CommandLine.arguments.count,
               let value = Float(CommandLine.arguments[index+1]), ChromaticAberration.levels.contains(value) {
                renderer.chromaticAberration = value
            }
            view.delegate = renderer
            window.contentView = view; previewWindow = window; previewRenderer = renderer
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
            if CommandLine.arguments.contains("--smoke-test") {
                let output = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts")
                try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
                let prefix = (CommandLine.arguments.contains("--dark-preview") ? "dark-" : "") + (renderer.intensity > 1.5 ? "storm-" : "")
                if renderer.intensity > 3.8 {
                    DispatchQueue.main.asyncAfter(deadline:.now()+1.5) { renderer.snapshotURL = output.appendingPathComponent(prefix+"rain-preview.png") }
                } else { renderer.snapshotURL = output.appendingPathComponent(prefix+"rain-preview.png") }
                DispatchQueue.main.asyncAfter(deadline:.now()+2) {
                    renderer.diagnosticWipe = (SIMD2(300,340),SIMD2(700,340))
                    renderer.snapshotURL = output.appendingPathComponent(prefix+"rain-wiped.png")
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+3.5) {
                    renderer.clear(animated:true); renderer.intensity = 0
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+4.0) {
                    renderer.snapshotURL = output.appendingPathComponent(prefix+"rain-clearing.png")
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+4.7) {
                    renderer.snapshotURL = output.appendingPathComponent(prefix+"rain-clear.png")
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+6.2) {
                    renderer.snapshotURL = output.appendingPathComponent(prefix+"rain-runoff.png")
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+6.9) {
                    if let error = renderer.gpuError { fputs("SMOKE_FAILED: \(error)\n",stderr); exit(1) }
                    guard renderer.completedFrames > 10 else { fputs("SMOKE_FAILED: no GPU frames\n",stderr); exit(1) }
                    print("SMOKE_OK: \(renderer.completedFrames) GPU frames completed; wet/wiped previews saved; \(NSScreen.screens.count) displays detected")
                    NSApp.terminate(nil)
                }
            }
        } catch { fputs("SMOKE_FAILED: \(error)\n",stderr); exit(1) }
    }
}

struct RainyScreenSettingsSnapshot {
    let mode: String
    let strength: Float
    let randomStrength: Bool
    let randomStrengthIntervalIndex: Int
    let dropScale: Float
    let wipeAnimation: WipeAnimation
    let frameRate: Int
    let renderQuality: RainRenderQuality
    let refraction: Bool
    let chromaticAberration: Float
    let resetOnMissionControl: Bool
    let allDisplays: Bool
    let selectedDisplayIDs: Set<String>
    let wipeShortcut: HotKeyShortcut?
    let stopToggleShortcut: HotKeyShortcut?
    let excludedAppBundleIDs: Set<String>
    let weatherLabel: String
    let locationTitle: String
    let usesManualLocation: Bool
    let running: Bool
    let rendering: Bool
    let language: L10n.Preference
    let loginEnabled: Bool
    let locationAuthorization: CLAuthorizationStatus
    let captureAuthorized: Bool
    let captureMessage: String?
    let captureFrameSummary: String
}

extension AppDelegate {
    func settingsSnapshot() -> RainyScreenSettingsSnapshot {
        RainyScreenSettingsSnapshot(mode: mode, strength: strength,
            randomStrength: randomStrength, randomStrengthIntervalIndex: randomStrengthIntervalIndex,
            dropScale: dropScale, wipeAnimation: wipeAnimation, frameRate: frameRate, renderQuality: renderQuality, refraction: refraction,
            chromaticAberration: chromaticAberration,
            resetOnMissionControl: resetOnMissionControl, allDisplays: allDisplays,
            selectedDisplayIDs: selectedDisplayIDs, wipeShortcut: wipeShortcut,
            stopToggleShortcut: stopToggleShortcut,
            excludedAppBundleIDs: excludedAppBundleIDs,
            weatherLabel: settingsPreviewMode ? L10n.text("現在地の天気を準備中", "Preparing weather for current location") : weatherLabel,
            locationTitle: weather.locationTitle, usesManualLocation: weather.usesManualLocation,
            running: isModeRunning, rendering: isActuallyRendering, language: L10n.preference,
            loginEnabled: SMAppService.mainApp.status == .enabled,
            locationAuthorization: weather.authorizationStatus,
            captureAuthorized: CGPreflightScreenCaptureAccess(),
            captureMessage: captureMessage,
            captureFrameSummary: "\(overlays.filter { $0.renderer.capture.hasFrame }.count) / \(overlays.count)")
    }

    func settingsSetLanguage(_ preference: L10n.Preference) {
        L10n.setPreference(preference, persist: !settingsPreviewMode)
        weather.localizationDidChange()
        updateTooltip()
        settingsController?.refreshFromApp()
    }

    func settingsSetMode(_ newMode: String) {
        if settingsPreviewMode {
            mode = ["auto", "demo", "off"].contains(newMode) ? newMode : "off"
            if mode == "auto" || mode == "demo" { modeBeforeStop = mode }
            weather.stop()
            apply()
            refreshSettingsWindow()
            return
        }
        switch newMode {
        case "auto": autoMode()
        case "demo": demoMode()
        default: stopMode()
        }
        refreshSettingsWindow()
    }

    func settingsSetStrength(_ value: Float) {
        let sender = NSMenuItem(); sender.representedObject = value
        setStrength(sender)
        refreshSettingsWindow()
    }

    func settingsSetRandomStrength(_ enabled: Bool) {
        if enabled {
            if !randomStrength { enableRandomStrength() }
        } else {
            randomStrength = false
            randomStrengthValue = strength
            randomStrengthTimer?.invalidate(); randomStrengthTimer = nil
            persist(false, key:"randomStrength")
            apply()
        }
        refreshSettingsWindow()
    }

    func settingsSetRandomInterval(_ index: Int) {
        let sender = NSMenuItem(); sender.representedObject = index
        setRandomStrengthInterval(sender)
        refreshSettingsWindow()
    }

    func settingsSetDropScale(_ value: Float) {
        let sender = NSMenuItem(); sender.representedObject = value
        setDropScale(sender)
        refreshSettingsWindow()
    }

    func settingsSetWipeAnimation(_ value: WipeAnimation) {
        wipeAnimation = value
        persist(value.rawValue, key:"wipeAnimation")
        for overlay in overlays { overlay.renderer.wipeAnimation = value }
        postStateChange()
        refreshSettingsWindow()
    }

    func settingsSetFrameRate(_ value: Int) {
        let sender = NSMenuItem(); sender.representedObject = value
        setFrameRate(sender)
        refreshSettingsWindow()
    }

    func settingsSetRenderQuality(_ value: RainRenderQuality) {
        renderQuality = value
        persist(value.rawValue,key:"renderQuality")
        for overlay in overlays { overlay.renderer.renderQuality = value }
        postStateChange()
        refreshSettingsWindow()
    }

    func settingsSetRefraction(_ enabled: Bool) {
        if settingsPreviewMode {
            refraction = enabled
            refreshSettingsWindow()
            return
        }
        if refraction != enabled { toggleRefraction() }
        refreshSettingsWindow()
    }

    func settingsSetChromaticAberration(_ value: Float) {
        guard ChromaticAberration.levels.contains(value) else { return }
        chromaticAberration = value
        persist(value,key:"chromaticAberration")
        for overlay in overlays { overlay.renderer.chromaticAberration = value }
        postStateChange()
        refreshSettingsWindow()
    }

    func settingsSetMissionControlReset(_ enabled: Bool) {
        if settingsPreviewMode {
            resetOnMissionControl = enabled
            refreshSettingsWindow()
            return
        }
        if resetOnMissionControl != enabled { toggleMissionControlReset() }
        refreshSettingsWindow()
    }

    func settingsSetLogin(_ enabled: Bool) {
        if settingsPreviewMode { return }
        if (SMAppService.mainApp.status == .enabled) != enabled { toggleLogin() }
        refreshSettingsWindow()
    }

    func settingsDisplayOptions() -> [(id: String, name: String, selected: Bool)] {
        NSScreen.screens.enumerated().map { index, screen in
            let id = displayIdentity(screen)
            return (id, "\(index + 1): \(screen.localizedName)", allDisplays || selectedDisplayIDs.contains(id))
        }
    }

    func settingsSetAllDisplays(_ enabled: Bool) {
        if settingsPreviewMode {
            allDisplays = enabled
            refreshSettingsWindow()
            return
        }
        if enabled { selectAllDisplays() }
        else {
            allDisplays = false
            if selectedDisplayIDs.isEmpty { selectedDisplayIDs = Set(NSScreen.screens.map(displayIdentity)) }
            saveDisplaySelection()
        }
        refreshSettingsWindow()
    }

    func settingsToggleDisplay(_ id: String) {
        if settingsPreviewMode {
            if allDisplays { selectedDisplayIDs = Set(NSScreen.screens.map(displayIdentity)); allDisplays = false }
            if selectedDisplayIDs.contains(id) { selectedDisplayIDs.remove(id) } else { selectedDisplayIDs.insert(id) }
            refreshSettingsWindow()
            return
        }
        let sender = NSMenuItem(); sender.representedObject = id
        toggleDisplay(sender)
        refreshSettingsWindow()
    }

    func settingsAvailableApps() -> [(id: String, name: String, selected: Bool)] {
        let running = runningApplicationsForAllowlist()
        var result = running.map { ($0.0, $0.1, excludedAppBundleIDs.contains($0.0)) }
        let known = Set(running.map(\.0))
        for id in excludedAppBundleIDs.subtracting(known).sorted() {
            result.append((id, "\(id) (not running)", true))
        }
        return result
    }

    func settingsToggleExcludedApp(_ id: String) {
        let sender = NSMenuItem(); sender.representedObject = id
        toggleExcludedApp(sender)
        refreshSettingsWindow()
    }

    func settingsAddExcludedApp() { addExcludedApp(); refreshSettingsWindow() }
    func settingsClearExcludedApps() { clearExcludedApps(); refreshSettingsWindow() }

    func settingsRegisterWipeShortcut(_ shortcut: HotKeyShortcut) -> String? {
        if settingsPreviewMode {
            wipeShortcut = shortcut
            postStateChange(); refreshSettingsWindow(); return nil
        }
        if shortcut == wipeShortcut && wipeHotKey?.isRegistered == true { return nil }
        let nextID = wipeHotKeyID == 2 ? UInt32(3) : UInt32(2)
        let candidate = GlobalHotKey(shortcut:shortcut,id:nextID) { [weak self] in self?.dry() }
        guard candidate.isRegistered else {
            return L10n.text("このショートカットは登録できません。以前の設定は保持しています。", "This shortcut is unavailable. The previous shortcut was kept.")
        }
        wipeHotKey = candidate; wipeHotKeyID = nextID; wipeShortcut = shortcut
        if !settingsPreviewMode { UserDefaults.standard.set(try? JSONEncoder().encode(shortcut),forKey:"wipeShortcut") }
        postStateChange(); refreshSettingsWindow(); return nil
    }

    func settingsClearWipeShortcut() {
        wipeHotKey = nil; wipeShortcut = nil
        if !settingsPreviewMode { UserDefaults.standard.removeObject(forKey:"wipeShortcut") }
        postStateChange(); refreshSettingsWindow()
    }

    func settingsRegisterStopToggleShortcut(_ shortcut: HotKeyShortcut) -> String? {
        if settingsPreviewMode {
            stopToggleShortcut = shortcut
            postStateChange(); refreshSettingsWindow(); return nil
        }
        if shortcut == stopToggleShortcut && stopToggleHotKey?.isRegistered == true { return nil }
        let nextID = stopToggleHotKeyID == 4 ? UInt32(5) : UInt32(4)
        let candidate = GlobalHotKey(shortcut:shortcut,id:nextID) { [weak self] in self?.toggleStopMode() }
        guard candidate.isRegistered else {
            return L10n.text("このショートカットは登録できません。固定停止キーや拭き上げキーと重複していないか確認してください。以前の設定は保持しています。", "This shortcut is unavailable. Check that it does not conflict with the fixed stop or wipe shortcut. The previous shortcut was kept.")
        }
        stopToggleHotKey = candidate; stopToggleHotKeyID = nextID; stopToggleShortcut = shortcut
        UserDefaults.standard.set(try? JSONEncoder().encode(shortcut),forKey:"stopToggleShortcut")
        postStateChange(); refreshSettingsWindow(); return nil
    }

    func settingsClearStopToggleShortcut() {
        stopToggleHotKey = nil; stopToggleShortcut = nil
        if !settingsPreviewMode { UserDefaults.standard.removeObject(forKey:"stopToggleShortcut") }
        postStateChange(); refreshSettingsWindow()
    }

    func settingsRefreshWeather() {
        guard !settingsPreviewMode else { return }
        weather.refreshOnce()
        refreshSettingsWindow()
    }

    func settingsSelectLocation() {
        guard !settingsPreviewMode else { return }
        selectLocation(); refreshSettingsWindow()
    }
    func settingsUseCurrentLocation() {
        guard !settingsPreviewMode else { return }
        useCurrentLocation(); refreshSettingsWindow()
    }
    func settingsOpenLocationSettings() { locationSettings() }
    func settingsOpenCaptureSettings() { captureSettings() }
    func settingsRequestCapturePermission() {
        guard !settingsPreviewMode else { return }
        requestCapturePermission(); refreshSettingsWindow()
    }
    func settingsShowHelp() { showHelp() }
    func settingsOpenAttribution() { attribution() }
    func settingsStatusText() -> (running: String, rendering: String) {
        (isModeRunning ? "Running" : "Stopped", isActuallyRendering ? "Rendering" : "Not Rendering")
    }

    func runSettingsStateTest() {
        let defaults = UserDefaults.standard
        let suiteName = Bundle.main.bundleIdentifier ?? "local.noa.RainGlass"
        let before = defaults.persistentDomain(forName: suiteName) ?? [:]
        let modes = ["auto", "demo", "off"]
        for modeValue in modes {
            settingsSetMode(modeValue)
            let snapshot = settingsSnapshot()
            let expectedRunning = modeValue != "off"
            guard snapshot.running == expectedRunning, !snapshot.rendering else {
                fputs("SETTINGS_STATE_FAILED: mode=\(modeValue) status mismatch\n", stderr)
                exit(1)
            }
        }
        settingsSetMode("demo")
        toggleStopMode()
        guard settingsSnapshot().mode == "off" else {
            fputs("SETTINGS_STATE_FAILED: demo stop toggle did not stop\n", stderr)
            exit(1)
        }
        toggleStopMode()
        guard settingsSnapshot().mode == "demo" else {
            fputs("SETTINGS_STATE_FAILED: demo stop toggle did not restore demo mode\n", stderr)
            exit(1)
        }
        settingsSetMode("auto")
        toggleStopMode()
        guard settingsSnapshot().mode == "off" else {
            fputs("SETTINGS_STATE_FAILED: auto stop toggle did not stop\n", stderr)
            exit(1)
        }
        toggleStopMode()
        guard settingsSnapshot().mode == "auto" else {
            fputs("SETTINGS_STATE_FAILED: auto stop toggle did not restore weather mode\n", stderr)
            exit(1)
        }
        settingsSetDropScale(1.75)
        settingsSetWipeAnimation(.vertical)
        settingsSetFrameRate(60)
        settingsSetRenderQuality(.balanced)
        let toggleShortcut = HotKeyShortcut(keyCode:17,modifiers:0,label:"T")
        _ = settingsRegisterStopToggleShortcut(toggleShortcut)
        settingsSetChromaticAberration(8)
        settingsSetChromaticAberration(99) // Unsupported values must be ignored.
        let configured = settingsSnapshot()
        guard abs(configured.dropScale - 1.75) < 0.01,
              configured.wipeAnimation == .vertical,
              configured.chromaticAberration == 8,
              configured.frameRate == 60,
              configured.renderQuality == .balanced,
              configured.stopToggleShortcut == toggleShortcut else {
            fputs("SETTINGS_STATE_FAILED: setting synchronization mismatch\n", stderr)
            exit(1)
        }
        let menu = NSMenu()
        menuWillOpen(menu)
        guard menu.items.contains(where: { $0.title.contains("1.75") }),
              menu.items.contains(where: { $0.title.contains("60 FPS") }) else {
            fputs("SETTINGS_STATE_FAILED: menu synchronization mismatch\n", stderr)
            exit(1)
        }
        let after = defaults.persistentDomain(forName: suiteName) ?? [:]
        guard NSDictionary(dictionary: before).isEqual(to: after) else {
            fputs("SETTINGS_STATE_FAILED: preview changed persistent defaults\n", stderr)
            exit(1)
        }
        print("SETTINGS_STATE_OK: mode/status, rendering guard, menu synchronization, and preview persistence")
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

@main enum RainyScreenMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
