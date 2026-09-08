import AppKit
import MetalKit
import MetalPerformanceShaders
import RainCore

enum WipeAnimation: Int {
    case drain = 0
    case vertical = 1
}

enum ChromaticAberration {
    static let levels: [Float] = [0,1,2,4,8,16]
}

struct Uniforms {
    var size: SIMD2<Float>
    var mouse: SIMD2<Float> = .zero
    var previousMouse: SIMD2<Float> = .zero
    var dt: Float = 1/30
    var intensity: Float = 1
    var time: Float = 0
    var wipeRadius: Float = 55
    var hasCapture: Float = 0
    var wipe: Float = 0
    var dropScale: Float = 1
    var mist: Float = 0
    var exclusionCount: Float = 0
    var sweepStart: Float = -1
    var sweepEnd: Float = -1
    var sweepAxis: Float = 0
    var chromaticAberration: Float = 1
}
struct GPUDrop {
    var position: SIMD2<Float>
    var radius: SIMD2<Float>
    var strength: Float
    var phase: Float = 0
    var tilt: Float = 0
    var kind: Float = 0
}

final class RainRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let capture: ScreenCapture
    private let queue: MTLCommandQueue
    private let dropPipeline: MTLRenderPipelineState
    private let trailPipeline: MTLRenderPipelineState
    private let glassPipeline: MTLRenderPipelineState
    private let hosePipeline: MTLComputePipelineState
    private let moisturePipeline: MTLComputePipelineState
    private var height: MTLTexture!
    private var wet: [MTLTexture] = []
    private var film: [MTLTexture] = []
    private var fallback: MTLTexture!
    private var smallScene: MTLTexture!
    private var softScene: MTLTexture!
    private var fogScene: MTLTexture!
    private lazy var scaler = MPSImageBilinearScale(device:device)
    private lazy var softBlur = MPSImageGaussianBlur(device:device,sigma:2.5)
    private lazy var fogBlur = MPSImageGaussianBlur(device:device,sigma:10)
    private var wetIndex = 0
    private var model: RainModel
    private var previousTime = CACurrentMediaTime()
    private var previousMouse: SIMD2<Float>?
    private var clearRequested = true
    private var clearAnimationProgress: Float?
    var intensity: Float = 0.8
    var dropScale: Float = 1
    var mistMode = false
    var renderQuality: RainRenderQuality = .high
    var chromaticAberration: Float = 1
    var wipeAnimation: WipeAnimation = .drain
    /// Screen-local rectangles where the rain layer must be transparent.
    /// The app delegate updates these from the current allowlisted app windows.
    var exclusionRects: [SIMD4<Float>] = []
    var wipeRadius: Float = 55
    var screenFrame: CGRect
    var previewTexture: MTLTexture?
    private var initialWetness: Double = 0
    private var initialFilm: Double = 0
    private(set) var completedFrames = 0
    private(set) var gpuError: String?
    var snapshotURL: URL?
    var diagnosticWipe: (SIMD2<Float>,SIMD2<Float>)?
    // Serial GPU access bounds frame memory and avoids writing into in-flight textures.
    private let inFlight = DispatchSemaphore(value: 1)

    init(view: MTKView, screenFrame: CGRect, seed: UInt64 = 42) throws {
        guard let device = view.device, let queue = device.makeCommandQueue() else {
            throw NSError(domain: "RainyScreen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metalを初期化できません"])
        }
        self.device = device; self.queue = queue; self.screenFrame = screenFrame
        model = RainModel(seed: seed)
        capture = ScreenCapture(device: device)
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("RainyScreen_RainyScreen.bundle/Rain.metal")
        let url = bundled.flatMap { FileManager.default.fileExists(atPath:$0.path) ? $0 : nil }
            ?? Bundle.module.url(forResource: "Rain", withExtension: "metal")!
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        let drops = MTLRenderPipelineDescriptor()
        drops.vertexFunction = library.makeFunction(name: "dropVertex")
        drops.fragmentFunction = library.makeFunction(name: "dropFragment")
        drops.colorAttachments[0].pixelFormat = .rg16Float
        drops.colorAttachments[0].isBlendingEnabled = true
        drops.colorAttachments[0].sourceRGBBlendFactor = .one
        drops.colorAttachments[0].destinationRGBBlendFactor = .one
        dropPipeline = try device.makeRenderPipelineState(descriptor: drops)
        drops.colorAttachments[0].rgbBlendOperation = .max
        trailPipeline = try device.makeRenderPipelineState(descriptor:drops)
        let glass = MTLRenderPipelineDescriptor()
        glass.vertexFunction = library.makeFunction(name: "fullVertex")
        glass.fragmentFunction = library.makeFunction(name: "glassFragment")
        glass.colorAttachments[0].pixelFormat = view.colorPixelFormat
        glassPipeline = try device.makeRenderPipelineState(descriptor: glass)
        moisturePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "moisture")!)
        hosePipeline = try device.makeComputePipelineState(function:library.makeFunction(name:"hoseFlow")!)
        super.init()
        resize(view.drawableSize)
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { resize(size) }
    private func resize(_ size: CGSize) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float,
                         width: max(1,Int(size.width)/2), height: max(1,Int(size.height)/2), mipmapped: false)
        desc.usage = [.shaderRead,.shaderWrite,.renderTarget]
        wet = [device.makeTexture(descriptor: desc)!,device.makeTexture(descriptor: desc)!]
        film = [device.makeTexture(descriptor:desc)!,device.makeTexture(descriptor:desc)!]
        let water = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rg16Float,
                         width:max(1,Int(size.width)),height:max(1,Int(size.height)),mipmapped:false)
        water.usage = [.shaderRead,.renderTarget]
        height = device.makeTexture(descriptor:water)
        let scene = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,
                         width:desc.width,height:desc.height,mipmapped:false)
        scene.usage = [.shaderRead,.shaderWrite]
        smallScene = device.makeTexture(descriptor:scene)
        softScene = device.makeTexture(descriptor:scene)
        fogScene = device.makeTexture(descriptor:scene)
        softBlur.edgeMode = .clamp; fogBlur.edgeMode = .clamp
        let f = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1,height: 1,mipmapped: false)
        fallback = device.makeTexture(descriptor: f)
        var zero: UInt32 = 0
        fallback.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        clearAnimationProgress = nil
        clearRequested = true
    }
    func clear(animated: Bool = false) {
        previousMouse = nil
        if animated {
            // Keep the existing drops and the accumulated film alive. The
            // animation is a physical runoff, not a post-process mask.
            model.beginSweep(vertical:wipeAnimation == .vertical)
            clearAnimationProgress = 0
            clearRequested = false
        } else {
            model.clear()
            clearAnimationProgress = nil
            clearRequested = true
        }
    }
    func preparePreview() {
        let previewMist = intensity > 0.001 && (mistMode || intensity <= 0.5)
        for _ in 0..<1350 {
            model.step(dt:1/30,size:SIMD2<Float>(1000,680)/dropScale,intensity:intensity,mist:previewMist)
        }
        initialWetness = 0.75
        // Seed only diagnostics so the first storm frame already represents
        // a soaked pane; live sessions still build the sheet from the top edge.
        initialFilm = 0
    }
    func draw(in view: MTKView) {
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let semaphore = inFlight
        command.addCompletedHandler { [weak self] buffer in
            semaphore.signal()
            DispatchQueue.main.async {
                self?.completedFrames += 1
                if let error = buffer.error { self?.gpuError = error.localizedDescription }
            }
        }
        let now = CACurrentMediaTime()
        let dt = Float(min(0.05,now-previousTime)); previousTime = now
        let size = SIMD2<Float>(Float(view.bounds.width),Float(view.bounds.height))
        var u = Uniforms(size: size)
        u.dt = dt; u.intensity = intensity; u.wipeRadius = wipeRadius; u.dropScale = dropScale
        u.chromaticAberration = chromaticAberration
        let sweeping = clearAnimationProgress != nil
        if let progress = clearAnimationProgress {
            let next = min(1,progress+dt/1.0)
            let vertical = wipeAnimation == .vertical
            u.sweepAxis = vertical ? 1 : 0
            let extent = (vertical ? size.y : size.x)+40*dropScale
            u.sweepStart = progress*extent-20*dropScale
            u.sweepEnd = next*extent-20*dropScale
            model.sweep(from:u.sweepStart/dropScale,to:u.sweepEnd/dropScale)
            clearAnimationProgress = next < 1 ? next : nil
            if next >= 1 { model.endSweep() }
            u.intensity = 0
        }
        let mistActive = intensity > 0.001 && (mistMode || intensity <= 0.5)
        u.mist = mistActive ? 1 : 0
        let maxExclusionRects = 16
        var exclusions = Array(exclusionRects.prefix(maxExclusionRects))
        u.exclusionCount = Float(exclusions.count)
        if exclusions.isEmpty {
            // Keep a valid buffer bound even when no app is excluded.
            exclusions = [SIMD4<Float>(repeating: -1)]
        }
        let global = NSEvent.mouseLocation
        let mouse = SIMD2<Float>(Float(global.x-screenFrame.minX),Float(screenFrame.maxY-global.y))
        if !sweeping && screenFrame.contains(global) {
            if let last = previousMouse, last != mouse {
                u.wipe = 1; u.previousMouse = last; u.mouse = mouse
                model.wipe(from: last/dropScale, to: mouse/dropScale,
                           radius: wipeRadius/dropScale, size:size/dropScale)
            }
            previousMouse = mouse
        } else { previousMouse = nil }
        if let (a,b) = diagnosticWipe {
            u.wipe = 1; u.previousMouse = a; u.mouse = b
            model.wipe(from:a/dropScale,to:b/dropScale,
                       radius:wipeRadius/dropScale, size:size/dropScale)
            diagnosticWipe = nil
        }
        model.step(dt: dt, size: size/dropScale, intensity: sweeping ? 0 : intensity,
                   mist: mistActive, quality: renderQuality)
        u.time = model.elapsed
        if clearRequested {
            for (index,texture) in (wet+film).enumerated() {
                let p = MTLRenderPassDescriptor()
                p.colorAttachments[0].texture = texture
                p.colorAttachments[0].loadAction = .clear
                p.colorAttachments[0].storeAction = .store
                p.colorAttachments[0].clearColor = MTLClearColorMake(index<2 ? initialWetness : initialFilm,0,0,0)
                command.makeRenderCommandEncoder(descriptor: p)?.endEncoding()
            }
            clearRequested = false
            initialWetness = 0
            initialFilm = 0
        }
        let delugeBlend: Float = intensity >= 3.8
            ? (abs(intensity-3.8) < 0.01 ? 0.4 : min(1,max(0,(intensity-3.8)/1.8)))
            : 0
        func gpuTrail(_ trail: Trail) -> GPUDrop {
            let delta = trail.end-trail.position
            let length = sqrt(delta.x*delta.x+delta.y*delta.y)
            let trailStrength = trail.isThroughFlow
                ? trail.radius*0.18*trail.life*trail.life
                : (trail.isRivulet
                    ? trail.radius*0.15*trail.life*trail.life
                    : trail.radius*0.12*trail.life*trail.life*(1+delugeBlend*1.20))
            return GPUDrop(position:(trail.position+trail.end)*0.5*dropScale,
                           radius:SIMD2(trail.radius,length*0.5+trail.radius)*dropScale,
                           strength:trailStrength*dropScale,tilt:-atan2(delta.x,delta.y),
                           kind:trail.isThroughFlow ? 1.25 : 1)
        }
        var instances = model.trails
            .filter { sweeping || !$0.isThroughFlow }
            .map(gpuTrail)
        if !sweeping {
            for rivulet in model.rivulets where rivulet.isThroughFlow {
                instances += rivulet.continuousSegments(size:size/dropScale).map(gpuTrail)
            }
        }
        let trailCount = instances.count
        let ridgeCells = max(0,model.ridge.volumes.count-1)
        if model.ridge.vertical {
            // Render several finite-volume cells as one continuous surface.
            // The endpoints retain local volume variation, while the larger
            // span prevents the cell grid from reading as individual beads.
            let cellsPerSurface = 8
            var start = 0
            while start < ridgeCells {
                let end = min(ridgeCells-1,start+cellsPerSurface-1)
                let top = model.ridge.pooledWidth(at:start)*dropScale*2
                let bottom = model.ridge.pooledWidth(at:end+1)*dropScale*2
                if max(top,bottom) > 0.1 {
                    let cellCount = Float(end-start+1)
                    let position = SIMD2((Float(start+end)*0.5+1)*SweepRidge.spacing,
                                         model.ridge.x)
                    let radius = SIMD2(cellCount*SweepRidge.spacing*0.5*dropScale,
                                       max(top,bottom))
                    instances.append(GPUDrop(position:position*dropScale,
                                             radius:radius,
                                             strength:1,phase:top,tilt:bottom,kind:3))
                }
                start = end+1
            }
        } else {
            for i in 0..<ridgeCells {
                // Horizontal mode keeps the existing per-cell profile.
                let top = model.ridge.pooledWidth(at:i)*dropScale*2
                let bottom = model.ridge.pooledWidth(at:i+1)*dropScale*2
                guard max(top,bottom) > 0.1 else { continue }
                let position = SIMD2(model.ridge.x,Float(i+1)*SweepRidge.spacing)
                let radius = SIMD2(max(top,bottom),SweepRidge.spacing*0.5*dropScale)
                instances.append(GPUDrop(position:position*dropScale,
                                         radius:radius,
                                         strength:1,phase:top,tilt:bottom,kind:2))
            }
        }
        instances += model.drops.map { drop in
            let stretch = min(0.7,drop.speed*0.0015)+(drop.heldBySweep ? 0.15 : drop.deformation)
            let verticalScale = drop.collected ? sqrt(1+stretch) : 1+stretch
            let depthScale = drop.collected ? Float(1.25) : (1-delugeBlend*0.78)/sqrt(1+stretch)
            let footprintScale: Float = drop.collected ? 1.6 : 1
            return GPUDrop(position:drop.position*dropScale,
                           radius:SIMD2(drop.footprintRadius/sqrt(1+stretch),drop.footprintRadius*verticalScale)*dropScale*footprintScale,
                           strength:drop.surfaceDepth*0.74*depthScale*dropScale,phase:drop.phase,
                           tilt:sin(drop.phase+model.elapsed*5)*drop.deformation*0.24)
        }
        let hp = MTLRenderPassDescriptor()
        hp.colorAttachments[0].texture = height
        hp.colorAttachments[0].loadAction = .clear; hp.colorAttachments[0].storeAction = .store
        hp.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
        if let encoder = command.makeRenderCommandEncoder(descriptor: hp) {
            encoder.setRenderPipelineState(dropPipeline)
            if !instances.isEmpty {
                let buffer = device.makeBuffer(bytes: instances,length: MemoryLayout<GPUDrop>.stride*instances.count,options: .storageModeShared)
                encoder.setVertexBuffer(buffer,offset: 0,index: 0)
                encoder.setVertexBytes(&u,length: MemoryLayout<Uniforms>.stride,index: 1)
                encoder.setRenderPipelineState(trailPipeline)
                if trailCount > 0 { encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:trailCount) }
                encoder.setRenderPipelineState(dropPipeline)
                if instances.count > trailCount {
                    encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:instances.count-trailCount,baseInstance:trailCount)
                }
            }
            encoder.endEncoding()
        }
        let next = 1-wetIndex
        if let compute = command.makeComputeCommandEncoder() {
            compute.setComputePipelineState(moisturePipeline)
            compute.setTexture(wet[wetIndex],index: 0); compute.setTexture(wet[next],index: 1)
            compute.setTexture(height,index:2)
            compute.setBytes(&u,length: MemoryLayout<Uniforms>.stride,index: 0)
            compute.dispatchThreads(MTLSize(width: wet[next].width,height: wet[next].height,depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16,height: 16,depth: 1))
            compute.endEncoding()
        }
        if let compute = command.makeComputeCommandEncoder() {
            compute.setComputePipelineState(hosePipeline)
            compute.setTexture(film[wetIndex],index:0); compute.setTexture(film[next],index:1)
            compute.setTexture(height,index:2)
            compute.setBytes(&u,length:MemoryLayout<Uniforms>.stride,index:0)
            compute.dispatchThreads(MTLSize(width:film[next].width,height:film[next].height,depth:1),
                                    threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
            compute.endEncoding()
        }
        wetIndex = next
        let captured = capture.texture()
        if let source = captured?.0 ?? previewTexture {
            scaler.encode(commandBuffer:command,sourceTexture:source,destinationTexture:smallScene)
            softBlur.encode(commandBuffer:command,sourceTexture:smallScene,destinationTexture:softScene)
            fogBlur.encode(commandBuffer:command,sourceTexture:smallScene,destinationTexture:fogScene)
        }
        u.hasCapture = previewTexture != nil ? 2 : (captured == nil ? 0 : 1)
        if let encoder = command.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(glassPipeline)
            encoder.setFragmentTexture(height,index: 0)
            encoder.setFragmentTexture(wet[wetIndex],index: 1)
            encoder.setFragmentTexture(captured?.0 ?? previewTexture ?? fallback,index: 2)
            encoder.setFragmentTexture(softScene,index:3)
            encoder.setFragmentTexture(fogScene,index:4)
            encoder.setFragmentTexture(film[wetIndex],index:5)
            encoder.setFragmentBytes(&u,length: MemoryLayout<Uniforms>.stride,index: 0)
            exclusions.withUnsafeBytes { bytes in
                encoder.setFragmentBytes(bytes.baseAddress!,length: bytes.count,index: 1)
            }
            encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
            encoder.endEncoding()
        }
        if let retained = captured?.1 { command.addCompletedHandler { _ in _ = retained } }
        if let url = snapshotURL {
            snapshotURL = nil
            let width = drawable.texture.width, height = drawable.texture.height
            let stride = ((width*4+255)/256)*256
            if let bytes = device.makeBuffer(length:stride*height,options:.storageModeShared),
               let blit = command.makeBlitCommandEncoder() {
                blit.copy(from:drawable.texture,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),
                          sourceSize:MTLSize(width:width,height:height,depth:1),to:bytes,destinationOffset:0,
                          destinationBytesPerRow:stride,destinationBytesPerImage:stride*height)
                blit.endEncoding()
                command.addCompletedHandler { buffer in
                    guard buffer.status == .completed else { return }
                    let data = Data(bytes:bytes.contents(),count:stride*height)
                    let info = CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little)
                    if let provider = CGDataProvider(data:data as CFData),
                       let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:stride,
                            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:info,provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent),
                       let png = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) {
                        try? png.write(to:url)
                    }
                }
            }
        }
        command.present(drawable); command.commit()
    }
}
