import AppKit
import ScreenCaptureKit
import Metal
import CoreVideo

/// Retains only the latest frame, in memory. Own application is explicitly excluded.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var frameStream: SCStream?
    private var frameDate = Date.distantPast
    private var cache: CVMetalTextureCache?
    private var generation = 0
    var onError: ((String) -> Void)?

    init(device: MTLDevice) {
        super.init()
        CVMetalTextureCacheCreate(nil,nil,device,nil,&cache)
    }
    @MainActor func start(displayID: CGDirectDisplayID, size: CGSize) async {
        generation += 1
        let token = generation
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard token == generation, let display = content.displays.first(where: {$0.displayID == displayID}) else { return }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            guard !own.isEmpty else { throw NSError(domain: "RainyScreen", code: 1, userInfo: [NSLocalizedDescriptionKey:"自身の画面を除外できませんでした"] ) }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = max(1,Int(size.width)); config.height = max(1,Int(size.height))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 3
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.capturesAudio = false
            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "RainyScreen.capture.\(displayID)"))
            stream = newStream
            setFrameStream(newStream)
            try await newStream.startCapture()
            if token != generation { try? await newStream.stopCapture() }
        } catch {
            guard token == generation else { return }
            onError?(error.localizedDescription)
        }
    }
    @MainActor func stop() {
        generation += 1
        let old = stream; stream = nil
        setFrameStream(nil)
        Task { try? await old?.stopCapture() }
    }
    private func setFrameStream(_ value: SCStream?) {
        lock.lock(); frameStream = value; latest = nil; lock.unlock()
    }
    var hasFrame: Bool { lock.lock(); defer { lock.unlock() }; return latest != nil }
    func texture() -> (MTLTexture, CVMetalTexture)? {
        lock.lock()
        let buffer = latest
        lock.unlock()
        guard let buffer, let cache else { return nil }
        var texture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm,
                                      CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &texture)
        guard result == kCVReturnSuccess, let texture, let metal = CVMetalTextureGetTexture(texture) else { return nil }
        return (metal,texture)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        lock.lock()
        defer { lock.unlock() }
        guard frameStream === stream else { return }
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int else { return }
        if SCFrameStatus(rawValue: rawStatus) == .idle {
            frameDate = Date()
            return
        }
        if SCFrameStatus(rawValue:rawStatus) == .blank || SCFrameStatus(rawValue:rawStatus) == .suspended || SCFrameStatus(rawValue:rawStatus) == .stopped {
            latest = nil
            return
        }
        guard SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        latest = buffer; frameDate = Date()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        guard frameStream === stream else { lock.unlock(); return }
        latest = nil; frameStream = nil; lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onError?(error.localizedDescription) }
    }
}
