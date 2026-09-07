import Foundation

/// A persistent gravity-fed stream on the glass.
///
/// Rivulets are deliberately separate from Drop and Trail: a drop creates a
/// short-lived track, while a rivulet keeps depositing connected segments for
/// several seconds. Its volume is represented by the segment width and is
/// still transferable by the existing wipe/sweep logic through Trail.
public struct Rivulet {
    public var position: SIMD2<Float>
    public private(set) var previous: SIMD2<Float>
    public private(set) var anchorX: Float
    public private(set) var speed: Float
    public private(set) var width: Float
    public let baseWidth: Float
    public let phase: Float
    public let drift: Float
    public let wobble: Float
    public let isThroughFlow: Bool
    /// Through-flows are temporary channels: after a long run they narrow
    /// into a thin film and disappear so another channel can form elsewhere.
    public let lifetime: Float
    public let fadeDuration: Float
    public let birthDuration: Float
    public private(set) var age: Float = 0
    private var rainScale: Float = 0
    public var isExpired: Bool { isThroughFlow && age >= lifetime }

    public init(position: SIMD2<Float>, baseWidth: Float, speed: Float,
                phase: Float, drift: Float, wobble: Float,
                isThroughFlow: Bool = false, lifetime: Float = 24,
                fadeDuration: Float = 4, birthDuration: Float = 2.4) {
        self.position = position
        self.previous = position
        self.anchorX = position.x
        self.baseWidth = baseWidth
        self.width = baseWidth
        self.speed = speed
        self.phase = phase
        self.drift = drift
        self.wobble = wobble
        self.isThroughFlow = isThroughFlow
        self.lifetime = max(0.1,lifetime)
        self.fadeDuration = max(0.1,fadeDuration)
        self.birthDuration = max(0,birthDuration)
    }

    /// Advances the stream and returns the connected segment deposited this
    /// frame. Width grows nonlinearly with rain intensity rather than making
    /// every stream equally thick.
    public mutating func step(dt: Float, size: SIMD2<Float>, intensity: Float) -> Trail? {
        guard dt > 0, size.x > 0, size.y > 0, !isExpired else { return nil }
        previous = position
        age += dt

        // Keep Heavy and Downpour visually distinct: Heavy increases the
        // number of channels, while Downpour also gives the channels more
        // cross-sectional depth.
        let rainScale = min(1, max(0, (intensity-0.35)/5.25))
        self.rainScale = rainScale
        let lifeFade = isThroughFlow
            ? min(1,max(0,(lifetime-age)/fadeDuration))
            : 1
        let targetWidth = baseWidth * (0.78 + rainScale*1.8) * lifeFade
        let widthResponse: Float = isThroughFlow ? 12 : 1.2
        width += (targetWidth-width)*min(1,dt*widthResponse)

        // Adhesion creates stick-slip motion: the stream slows on some glass
        // patches and accelerates again once enough water has accumulated.
        let patch = 0.5 + 0.5*sin(position.y*0.017 + phase)
        let pulse = sin(age*(0.65+rainScale*0.4)+phase)
        let downpourBoost: Float = intensity >= 5.6 ? 35 : 0
        // Water collected from above increases the effective volume of the
        // downstream section. Treat the resulting gravity gain separately
        // from the local glass friction so lower sections become faster
        // without removing stick-slip pauses.
        let depth = min(1,max(0,position.y/max(1,size.y)))
        let rainFeed = 0.38 + rainScale*0.62
        let accumulatedVolume = 1 + depth*(0.55+rainFeed*0.65)
        let downstreamGain = 0.88 + depth*(0.32+rainFeed*0.22)
        let targetSpeed = (34 + rainScale*105 + downpourBoost)
            * downstreamGain * sqrt(accumulatedVolume)
        let acceleration = 24 + rainScale*65 + pulse*9 - patch*8
            + depth*(14+rainFeed*20)
        speed = min(targetSpeed*1.4, max(12, speed + acceleration*dt))
        position.y += speed*dt
        position.x += (drift + sin(position.y*0.012+phase)*wobble)*speed*dt
        position.x = min(size.x+40, max(-40, position.x))

        let delta = position-previous
        let length = sqrt(delta.x*delta.x+delta.y*delta.y)
        guard length > 0.1, width > 0.15 else { return nil }
        return Trail(position:previous, end:position, radius:max(0.8,width), life:1,
                     volume:max(0.001,width*width*length*0.08), isRivulet:true,
                     isThroughFlow:isThroughFlow)
    }

    public mutating func reset(at position: SIMD2<Float>) {
        self.position = position
        previous = position
        // A through-flow's moving head can wrap from the bottom to the top,
        // but its full-height channel must not jump sideways at that moment.
        // Keep anchorX and age until the channel's actual lifetime ends.
        if !isThroughFlow {
            anchorX = position.x
            age = 0
        }
        speed = max(12, speed*0.35)
    }

    /// Returns a continuously connected path from the top edge to the bottom
    /// edge. The path is a visual water channel; the moving head and deposited
    /// segments still provide the flow timing and optical displacement.
    public func continuousSegments(size: SIMD2<Float>) -> [Trail] {
        guard isThroughFlow, size.x > 0, size.y > 0, !isExpired, width > 0.15 else { return [] }
        let count = max(10,Int(size.y/48))
        let step = size.y/Float(count)
        // Keep the channel attached to the glass. The water mass travels
        // downward through it; the entire river should not sway like smoke.
        let personality = 0.5 + 0.5*abs(sin(phase*1.731))
        let movement = phase + age*(0.025+personality*0.055)
        func x(at y: Float) -> Float {
            // Three spatial scales create a river-like centerline instead of
            // a single regular sine wave: a broad bend, medium meander, and
            // small edge turbulence. The path remains connected at every
            // frame, so it reads as one liquid channel.
            let broad = sin(y*0.0048+movement)*30
            let meander = sin(y*0.0105+phase*1.37+age*(0.02+personality*0.06))*15
            let turbulence = sin(y*0.024+phase*2.11+age*(0.03+personality*0.08))*6
            let returnBend = sin(y*0.0019+phase*0.61)*11
            return min(size.x+30,max(-30,anchorX+broad+meander+turbulence+returnBend))
        }
        var result: [Trail] = []
        result.reserveCapacity(count)
        let birth = birthDuration > 0 ? min(1,max(0,age/birthDuration)) : 1
        let fade = min(1,max(0,(lifetime-age)/fadeDuration))*birth
        for index in 0..<count {
            let y0 = Float(index)*step
            let y1 = Float(index+1)*step
            let p0 = SIMD2(x(at:y0),y0)
            let p1 = SIMD2(x(at:y1),y1)
            // Water gathers into pools and pinches at contact-line bottlenecks.
            // Keep the modulation smooth so it forms one liquid body rather
            // than a row of equally sized droplets.
            let slowPool = 0.48 + 1.02*(0.5+0.5*sin(y0*0.0063+phase*0.83))
            let middlePool = 0.68 + 0.58*(0.5+0.5*sin(y0*0.016+phase*1.91))
            // A water bulge is advected down the channel. Its velocity and
            // phase differ per rivulet, so the streams do not pulse in sync.
            // The lower part carries the accumulated upstream volume. Its
            // advection phase therefore advances faster than the top part,
            // rather than making the whole channel move at one constant rate.
            let depth = min(1,max(0,y0/max(1,size.y)))
            let rainFeed = 0.38 + rainScale*0.62
            let accumulatedVolume = 1 + depth*(0.55+rainFeed*0.65)
            let downstreamGain = 0.88 + depth*(0.32+rainFeed*0.22)
            let localFlowSpeed = max(14,speed)*downstreamGain*sqrt(accumulatedVolume)
            let flowingY = y0-age*localFlowSpeed
            let massGain = 0.9 + depth*(0.25+rainFeed*0.4)
            let movingPool = 0.78 + 0.46*(0.5+0.5*sin(flowingY*0.012+phase*2.37))
            let localWidth = width*massGain*slowPool*middlePool*movingPool*birth
            result.append(Trail(position:p0,end:p1,radius:max(0.15,localWidth),life:fade,
                                volume:0,isRivulet:true,isThroughFlow:true))
        }
        return result
    }
}
