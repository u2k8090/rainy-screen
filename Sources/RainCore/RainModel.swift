import Foundation

public struct WeatherResponse: Decodable {
    public let current: Current
    public struct Current: Decodable {
        public let time: Double
        public let rain: Double
        public let showers: Double
        public let weather_code: Int
        public var isRaining: Bool {
            rain + showers > 0 || [51,53,55,56,57,61,63,65,66,67,80,81,82,95,96,99].contains(weather_code)
        }
        public var intensity: Float {
            guard isRaining else { return 0 }
            // Open-Meteo's current rain/showers values are precipitation
            // amounts for the recent 15-minute model interval. Use the
            // weather code as a categorical floor, then let the amount move
            // continuously between the app's visual intensity bands.
            let codeFloor: Float
            switch weather_code {
            case 51,56,61,66,80:
                codeFloor = 0.8
            case 53,63,81:
                codeFloor = 1.4
            case 55,57:
                codeFloor = 2.4
            case 65,67,95:
                codeFloor = 3.8
            case 82,96,99:
                codeFloor = 5.6
            default:
                codeFloor = 0.35
            }
            let recentAmount = max(0,rain+showers)
            let amountIntensity = min(5.6, max(0.35,
                0.35+log(1+recentAmount*4)*1.35))
            return max(codeFloor,Float(amountIntensity))
        }
        public func isFresh(at date: Date) -> Bool {
            let age = date.timeIntervalSince1970 - time
            return age >= -300 && age < 1800
        }
    }
}

public func segmentDistance(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
    let d = b - a
    let l = d.x*d.x + d.y*d.y
    let v = p - a
    let t = l > 0 ? min(1, max(0, (v.x*d.x + v.y*d.y)/l)) : 0
    let q = p - (a + t*d)
    return sqrt(q.x*q.x + q.y*q.y)
}

/// Visual flow constants calibrated against the Strong rain setting
/// (intensity 2.4). Keep these together while tuning the look; the intensity
/// value should only scale the existing storm/deluge behavior around them.
private enum FlowTuning {
    static let baseGravity: Float = 460
    static let strongReferenceIntensity: Float = 2.4
    static let lowerRainFlowExponent: Float = 1.7
    static let mistFastDropRadius: Float = 3.8
    static let heavyStrongWeight: Float = 0.60
    static let heavyDelugeWeight: Float = 0.40
    /// Keep the number of flowing beads close to Heavy while making each
    /// flowing bead faster and optically stronger.
    static let delugeFlowProbability: Float = 0.13
    /// 豪雨の全流動粒を現在の豪雨設定からさらに2倍へ引き上げる。
    static let delugeSpeedMultiplier: Float = 3.0
    /// 大粒・高速粒は、現在の高速豪雨設定からさらに2倍へ引き上げる。
    static let delugeFastDropSpeedMultiplier: Float = 4.0
    static let delugeFastDropRadius: Float = 4.5
    static let delugeFastDropSpeedThreshold: Float = 80
    static let delugeStallProbabilityScale: Float = 0.28
    static let delugeGripScale: Float = 0.40
    static let delugeTrailWidthScale: Float = 1.35
    static let delugeTrailDepositScale: Float = 1.20
    static let delugeTrailLifetimeScale: Float = 1.60
    static let delugeTrailCaptureMaxDropRadius: Float = 4.2
    static let delugeTrailCaptureMaxSpeed: Float = 80
    static let delugeTrailCaptureRadiusScale: Float = 1.20
    static let delugeTrailCaptureAreaScale: Float = 0.035
    static let delugeTrailMaxRadius: Float = 8.5
    static let kineticResistanceRatio: Float = 0.56
    static let radiusResistanceRatio: Float = 0.015
    static let stormGripBase: Float = 0.08
    static let stormGripVariation: Float = 0.12
    static let gripWavePrimary: Float = 0.48
    static let gripWaveSecondary: Float = 0.24
    static let gripWaveTertiary: Float = 0.08
    static let breakawayPulseRatio: Float = 0.35
    static let movingSpeedThreshold: Float = 8
    static let restingSpeedThreshold: Float = 2
    static let breakawaySpeed: Float = 6
    static let breakawaySpeedPerRadius: Float = 1.5
    static let stallRate: Float = 0.10
    static let stallRateVariation: Float = 0.32
    static let stormStallRate: Float = 0.12
    static let stallDurationBase: Float = 0.32
    static let stallDurationVariation: Float = 0.65
    static let stallDurationByTendency: Float = 1.25
    static let stallCooldownBase: Float = 0.70
    static let stallCooldownVariation: Float = 1.40
    static let stallCooldownByTendency: Float = 2.0
    static let viscousDragByTendency: Float = 8
}

/// Volume is measured in radius-cubed units; the common spherical-cap factor cancels.
public struct Drop {
    public var position: SIMD2<Float>
    public var previous: SIMD2<Float>
    public var volume: Float
    public var speed: Float
    /// Persistent per-drop variation keeps otherwise identical beads from
    /// marching in lockstep.
    public var speedFactor: Float
    public var phase: Float
    public var adhesion: Float
    /// Constant lateral velocity component. Near-zero values read as a
    /// straight vertical fall, while a small signed value gives a clean
    /// diagonal track.
    public var drift: Float
    /// Per-drop lateral oscillation. Straight drops keep this low; meandering
    /// drops use a larger value to retain the irregular runoff.
    public var wobble: Float
    /// Probability bias for contact-line pinning and temporary stops.
    public var stallTendency: Float
    /// Lateral impulse from the optional cursor blower effect.
    public var blowVelocity: SIMD2<Float> = .zero
    public var blowRemaining: Float = 0
    /// Hysteresis state for static/dynamic contact resistance.
    /// A drop needs more force to start moving than it needs to keep moving.
    public var isMoving: Bool = false
    public var deformation: Float = 0
    public var age: Float = 0
    public var stallTimer: Float = 0
    public var stallCooldown: Float = 0
    public var heldBySweep: Bool = false
    public var releasedFromSweep: Bool = false
    public var collected: Bool = false
    public var radius: Float { pow(max(0.001,volume),1/3) }
    /// Collected water spreads over the pane while its depth stays bounded.
    /// footprint² × depth preserves the same radius-cubed volume units.
    public var surfaceDepth: Float { collected ? min(radius,4) : radius }
    public var footprintRadius: Float { sqrt(max(0.001,volume)/surfaceDepth) }
    public init(position: SIMD2<Float>, radius: Float, speed: Float = 0, phase: Float = 0, adhesion: Float = 1, speedFactor: Float = 1, drift: Float = 0, wobble: Float = 0, stallTendency: Float = 0) {
        self.position = position; previous = position; volume = radius*radius*radius
        self.speed = speed; self.phase = phase; self.adhesion = adhesion; self.speedFactor = speedFactor
        self.drift = drift; self.wobble = wobble; self.stallTendency = stallTendency
    }
}
public struct Trail {
    public var position: SIMD2<Float>
    public var end: SIMD2<Float>
    public var radius: Float
    public var life: Float
    public var volume: Float = 0
    public var isRivulet: Bool = false
    public var isThroughFlow: Bool = false
    /// Endpoint width for continuous channels; ordinary deposited trails stay uniform.
    public var endRadius: Float? = nil
}
public enum RainRenderQuality: Int, CaseIterable {
    case high = 0
    case balanced = 1
    case light = 2

    public var coalescenceInterval: Int {
        switch self {
        case .high: return 1
        case .balanced: return 2
        case .light: return 3
        }
    }

    public var trailHistoryScale: Float {
        switch self {
        case .high: return 1
        case .balanced: return 0.78
        case .light: return 0.58
        }
    }
}

public enum CursorEffect: Int, CaseIterable {
    case none = 0
    case wipe = 1
    case blower = 2
}

public enum BlowerStrength: Int, CaseIterable {
    case verySoft = 0, soft, standard, strong, veryStrong

    public var impulse: Float {
        switch self {
        case .verySoft: return 150
        case .soft: return 220
        case .standard: return 300
        case .strong: return 410
        case .veryStrong: return 560
        }
    }

    public var travelDistance: Float {
        switch self {
        case .verySoft: return 45
        case .soft: return 70
        case .standard: return 100
        case .strong: return 140
        case .veryStrong: return 190
        }
    }

    /// The current blower radius is the minimum area. Stronger settings
    /// expand the affected circle together with the impulse and travel.
    public var radiusMultiplier: Float {
        switch self {
        case .verySoft: return 1.0
        case .soft: return 2.25
        case .standard: return 3.5
        case .strong: return 4.75
        case .veryStrong: return 6.0
        }
    }

    public var clearRate: Float {
        switch self {
        case .verySoft: return 0.5
        case .soft: return 1.0
        case .standard: return 1.5
        case .strong: return 2.25
        case .veryStrong: return 3.0
        }
    }
}

public enum BlowerSize: Int, CaseIterable {
    case smallest = 0, small, standard, large, largest

    public var multiplier: Float {
        switch self {
        case .smallest: return 0.5
        case .small: return 0.75
        case .standard: return 1.0
        case .large: return 1.5
        case .largest: return 2.0
        }
    }
}

public struct RainModel {
    public private(set) var drops: [Drop] = []
    public private(set) var trails: [Trail] = []
    public private(set) var rivulets: [Rivulet] = []
    public private(set) var elapsed: Float = 0
    public private(set) var mergerCount = 0
    public private(set) var stallCount = 0
    public private(set) var ridge = SweepRidge()
    private var spawn: Float = 0
    private var rivuletSpawn: Float = 0
    private var randomState: UInt64
    private var sweepVertical = false
    private var sweepActive = false
    private var stepCount = 0
    public init(seed: UInt64 = 42) { randomState = seed }
    public mutating func add(_ drop: Drop) { drops.append(drop) }
    private mutating func random() -> Float {
        randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
        return Float(randomState >> 40) / Float(1 << 24)
    }
    public mutating func clear() {
        ridge = SweepRidge(); sweepVertical = false; sweepActive = false
        drops.removeAll(); trails.removeAll(); rivulets.removeAll()
        elapsed = 0; spawn = 0; rivuletSpawn = 0; mergerCount = 0; stallCount = 0; stepCount = 0
    }
    public mutating func wipe(from a: SIMD2<Float>, to b: SIMD2<Float>, radius: Float, size: SIMD2<Float>? = nil) {
        drops.removeAll { segmentDistance($0.position, a, b) < radius + $0.radius }
        trails.removeAll { segmentDistance($0.position, a, b) < radius + $0.radius || segmentDistance($0.end,a,b) < radius + $0.radius }
        rivulets.removeAll { rivulet in
            if rivulet.isThroughFlow, let size {
                return rivulet.continuousSegments(size:size).contains {
                    segmentDistance($0.position,a,b) < radius+$0.radius ||
                    segmentDistance($0.end,a,b) < radius+$0.radius
                }
            }
            return segmentDistance(rivulet.position,a,b) < radius+rivulet.width
        }
    }

    public mutating func blow(at center: SIMD2<Float>, radius: Float, strength: BlowerStrength) {
        guard radius > 0 else { return }
        for index in drops.indices {
            let delta = drops[index].position-center
            let distance = sqrt(delta.x*delta.x + delta.y*delta.y)
            let falloff = max(0,1-distance/radius)
            guard falloff > 0 else { continue }
            let direction = distance > 0.01 ? delta/distance : SIMD2<Float>(0,-1)
            drops[index].blowVelocity += direction*(strength.impulse*falloff*falloff)
            drops[index].blowRemaining = max(drops[index].blowRemaining,
                                              strength.travelDistance*max(0.35,falloff))
            drops[index].isMoving = true
        }
        for index in rivulets.indices {
            // Heavy/deluge through-flows are persistent channels anchored to
            // the glass. Blowing individual droplets must not slide the whole
            // river sideways; only ordinary local rivulets can be displaced.
            guard !rivulets[index].isThroughFlow else { continue }
            let delta = rivulets[index].position-center
            let distance = sqrt(delta.x*delta.x + delta.y*delta.y)
            let falloff = max(0,1-distance/radius)
            guard falloff > 0 else { continue }
            let direction = distance > 0.01 ? delta/distance : SIMD2<Float>(0,-1)
            rivulets[index].blow(direction:direction,
                                  amount:strength.impulse*falloff*falloff)
        }
    }
    public mutating func beginSweep(vertical: Bool = false) {
        sweepVertical = vertical
        sweepActive = true
        ridge.configure(vertical:vertical)
        drops += ridge.releaseAll()
        for i in drops.indices { drops[i].releasedFromSweep = false }
    }

    public mutating func sweep(from start: Float, to end: Float) {
        guard end > start else { return }
        ridge.move(to:end)
        var remainingDrops: [Drop] = []
        for bead in drops {
            let coordinate = sweepVertical ? bead.position.y : bead.position.x
            if !bead.releasedFromSweep && coordinate+bead.footprintRadius >= start
                && coordinate-bead.footprintRadius <= end {
                let cross = sweepVertical ? bead.position.x : bead.position.y
                ridge.collect(volume:bead.volume,coordinate:cross,radius:bead.footprintRadius,boundary:end)
            } else { remainingDrops.append(bead) }
        }
        drops = remainingDrops
        var remainingTrails: [Trail] = []
        for trail in trails {
            let center = (trail.position+trail.end)*0.5
            let axisStart = sweepVertical
                ? min(trail.position.y,trail.end.y)-trail.radius
                : min(trail.position.x,trail.end.x)-trail.radius
            let axisEnd = sweepVertical
                ? max(trail.position.y,trail.end.y)+trail.radius
                : max(trail.position.x,trail.end.x)+trail.radius
            // A rain trail can be much longer than one sweep step. Testing
            // only its center leaves a vertical streak straddling the moving
            // boundary, making collected water look like individual drops.
            if axisEnd >= start && axisStart < end {
                let cross = sweepVertical ? center.x : center.y
                ridge.collect(volume:trail.volume,coordinate:cross,radius:trail.radius,boundary:end)
            } else { remainingTrails.append(trail) }
        }
        trails = remainingTrails
    }

    public mutating func endSweep() {
        drops += ridge.releaseAll()
        sweepActive = false
        rivulets.removeAll()
        coalesce()
    }

    public mutating func step(dt raw: Float, size: SIMD2<Float>, intensity: Float, mist: Bool = false,
                              quality: RainRenderQuality = .high) {
        let dt = min(max(raw, 0), 0.05)
        guard dt > 0, size.x > 0, size.y > 0 else { return }
        elapsed += dt
        stepCount += 1
        drops += ridge.step(dt:dt,height:sweepVertical ? size.x : size.y)
        // 豪雨 keeps 大雨's arrival rate so the renderer is not flooded with
        // sprites. It instead favours larger beads and lets their size drive
        // the speed of the runoff.
        let baseIntensity = min(max(0,intensity),3.8)
        let baseStorm = min(1,max(0,(baseIntensity-1.5)/4.1))
        let isDeluge = intensity > 3.8
        let isHeavyBlend = abs(intensity-3.8) < 0.01
        let delugeBlend: Float = isDeluge
            ? min(1,max(0,(intensity-3.8)/1.8))
            : (isHeavyBlend ? FlowTuning.heavyDelugeWeight : 0)
        let isMist = intensity > 0.001 && (mist || intensity <= 0.5)
        let dropLimit = isMist ? 3200 : Int(1800 + baseStorm*1800)
        let spawnRate = isMist ? 11.5 : min(8.4,baseIntensity)
        // Strong is the speed reference. Below Strong, suppress only the
        // fraction of newly born beads that are already flowing; the water
        // that grows into a large bead keeps the Strong runoff speed.
        let lowerRainScale = min(1,max(0,baseIntensity/FlowTuning.strongReferenceIntensity))
        let lowerRainFlowScale = pow(lowerRainScale,FlowTuning.lowerRainFlowExponent)
        let strongFlowProbability = 0.035
            + min(1,max(0,(FlowTuning.strongReferenceIntensity-1.5)/4.1))*0.12
        let regularFlowProbability = (0.035+baseStorm*0.12)*lowerRainFlowScale
        let flowProbability = isHeavyBlend
            ? strongFlowProbability*FlowTuning.heavyStrongWeight
                + FlowTuning.delugeFlowProbability*FlowTuning.heavyDelugeWeight
            : (isDeluge ? FlowTuning.delugeFlowProbability : regularFlowProbability)
        if !sweepActive {
            updateRivulets(dt:dt,size:size,intensity:intensity)
        }
        spawn += dt * spawnRate * size.x / 9
        let existingMistRunners = isMist
            ? drops.reduce(0) { $0 + ($1.radius > 3.2 && $1.speed > 0 ? 1 : 0) }
            : 0
        var spawnedMistRunners = 0
        while spawn >= 1 {
            spawn -= 1
            if drops.count >= dropLimit { drops.removeFirst() }
            let running: Bool
            if isMist {
                // Keep the pane covered in pinned mist, with only one or two
                // larger beads per display occasionally breaking loose.
                running = existingMistRunners+spawnedMistRunners < 2 && random() < 0.00012
                if running { spawnedMistRunners += 1 }
            } else {
                running = random() < flowProbability
            }
            let radiusBias: Float = isDeluge ? 0.68 : 1
            let smallRadius = isMist
                ? 0.62 + pow(random(),2.8)*1.9
                : 1.15 + pow(random(),isDeluge ? 0.82 : 2.4)*3.3
            let runningRadius = isMist
                ? 4.2 + random()*2.4
                : 3.6 + pow(random(),radiusBias)*(2.4+baseStorm*2.5)
            let r: Float = running ? runningRadius : smallRadius
            let y: Float = random()*size.y
            let trajectory = random()
            let drift: Float
            let wobble: Float
            if isMist {
                drift = (random()-0.5)*0.018
                wobble = 0.004+random()*0.012
            } else if trajectory < 0.32 {
                // A substantial share falls almost vertically.
                drift = (random()-0.5)*0.028
                wobble = 0.004+random()*0.012
            } else if trajectory < 0.56 {
                // Some tracks lean consistently without turning into waves.
                drift = (random()-0.5)*0.105
                wobble = 0.012+random()*0.025
            } else {
                // The remaining drops retain the more irregular natural runoff.
                drift = (random()-0.5)*0.12
                wobble = 0.045+random()*0.08
            }
            drops.append(Drop(position:SIMD2(random()*size.x,y),radius:r,
                              speed:0,phase:random()*100,
                              adhesion:isMist ? 0.65+random()*0.65 : 0.95+random()*1.1,
                              speedFactor:0.58+pow(random(),0.72)*0.96,drift:drift,wobble:wobble,
                              stallTendency:0.2+random()*0.8))
        }
        if delugeBlend > 0 { absorbDelugeDropsIntoTrails(blend:delugeBlend) }
        for i in drops.indices {
            var d = drops[i]
            d.previous = d.position; d.age += dt
            if d.blowRemaining > 0 && (d.blowVelocity.x != 0 || d.blowVelocity.y != 0) {
                let displacement = d.blowVelocity*dt
                let distance = sqrt(displacement.x*displacement.x + displacement.y*displacement.y)
                let scale = distance > d.blowRemaining ? d.blowRemaining/distance : 1
                d.position += displacement*scale
                d.blowRemaining = max(0,d.blowRemaining-distance*scale)
                d.blowVelocity *= exp(-dt*2.8)
                let remainingSpeed = sqrt(d.blowVelocity.x*d.blowVelocity.x + d.blowVelocity.y*d.blowVelocity.y)
                if d.blowRemaining == 0 || remainingSpeed < 1 {
                    d.blowRemaining = 0
                    d.blowVelocity = .zero
                }
            }
            d.stallCooldown = max(0,d.stallCooldown-dt)
            var stalled = false
            if d.stallTimer > 0 {
                d.stallTimer = max(0,d.stallTimer-dt)
                d.speed *= exp(-dt*16)
                stalled = true
                if d.stallTimer == 0 { d.speed = max(8,d.speed) }
            } else if d.stallCooldown == 0 && d.stallTendency > 0 && d.speed > 24,
                      random() < dt*(FlowTuning.stallRate
                                     + FlowTuning.stallRateVariation*d.stallTendency
                                     + baseStorm*FlowTuning.stormStallRate)
                                     * (isDeluge ? FlowTuning.delugeStallProbabilityScale : 1) {
                d.stallTimer = FlowTuning.stallDurationBase
                    + random()*(FlowTuning.stallDurationVariation
                                + FlowTuning.stallDurationByTendency*d.stallTendency)
                d.stallCooldown = FlowTuning.stallCooldownBase
                    + random()*(FlowTuning.stallCooldownVariation
                                + FlowTuning.stallCooldownByTendency*d.stallTendency)
                d.speed *= 0.12
                stalled = true
                stallCount += 1
            }
            // Give released sweep water a brisk runoff without speeding up
            // ambient rain or changing the contact-boundary accumulation.
            let motionDT = dt * (d.collected && d.releasedFromSweep ? 1.8 : 1)
            let r = d.radius
            // Mist keeps its barely-moving pin droplets, but a bead that has
            // grown past the runner size uses the same speed as Strong rain.
            let speedMultiplier: Float
            if isMist && r < FlowTuning.mistFastDropRadius {
                speedMultiplier = 0.18
            } else if delugeBlend > 0 && (r >= FlowTuning.delugeFastDropRadius
                                   || d.speed > FlowTuning.delugeFastDropSpeedThreshold) {
                speedMultiplier = 1+delugeBlend*(FlowTuning.delugeFastDropSpeedMultiplier-1)
            } else {
                speedMultiplier = 1+delugeBlend*(FlowTuning.delugeSpeedMultiplier-1)
            }
            // Gravity scales with the bead's effective cross-section and its
            // persistent speed variation. This is deliberately stylized: the
            // goal is to preserve the visual relationship between volume and
            // runoff without simulating a full fluid solver.
            let sizeFactor = 0.72 + min(1.0,max(0,r-1)/6.0)*0.88
            let gravityForce = FlowTuning.baseGravity * sizeFactor * d.speedFactor

            // A spatial adhesion field plus different static/kinetic thresholds
            // produces stick-slip. Static resistance is only used to decide
            // whether a bead breaks free; once it moves, the lower kinetic
            // resistance lets it continue as a narrow, fast stream.
            let patch = 1 + FlowTuning.gripWavePrimary*sin(d.position.y*0.055+d.phase)
                + FlowTuning.gripWaveSecondary*sin(d.position.y*0.19+d.phase*2)
                + FlowTuning.gripWaveTertiary*sin(d.position.x*0.017+d.phase*0.73)
            let stormGrip = 1 + baseStorm*(FlowTuning.stormGripBase
                                            + FlowTuning.stormGripVariation*d.stallTendency)
                                            * (isDeluge ? FlowTuning.delugeGripScale : 1)
            let glassRetention = FlowTuning.baseGravity * pow(3.35/r,2)
                * d.adhesion * patch * stormGrip
            let staticResistance = d.heldBySweep
                ? max(glassRetention,FlowTuning.baseGravity*pow(8.5/r,2))
                : glassRetention
            let kineticRatio = FlowTuning.kineticResistanceRatio
                + min(0.16,r*FlowTuning.radiusResistanceRatio)
            let kineticResistance = staticResistance * kineticRatio
            let cadence = 0.48 + min(1.6,d.speedFactor)*0.33 + min(r,8)*0.035
            let speedPulse = sin(d.age*cadence+d.phase*1.37)*(28+min(r,8)*5)
                + sin(d.age*(cadence*0.43+0.17)-d.phase*0.61)*14

            if d.speed > FlowTuning.movingSpeedThreshold { d.isMoving = true }
            if !d.isMoving && !stalled {
                // A small positive margin creates a visible breakaway rather
                // than leaving the bead hovering at an almost-zero speed.
                let breakawayForce = gravityForce + speedPulse*FlowTuning.breakawayPulseRatio
                if breakawayForce > staticResistance {
                    d.isMoving = true
                    d.speed = max(d.speed,FlowTuning.breakawaySpeed
                                      + min(16,r*FlowTuning.breakawaySpeedPerRadius))
                } else {
                    d.speed = 0
                }
            }

            if !stalled && d.isMoving {
                let viscousDrag = d.speed*(10+FlowTuning.viscousDragByTendency*d.stallTendency)
                    / max(r,1)
                let acceleration = ((gravityForce - kineticResistance - viscousDrag
                                    - d.speed*d.speed/(max(r,1)*90)) + speedPulse)
                    * speedMultiplier
                let sizeLimit = (320 + min(330,r*52))*d.speedFactor
                d.speed = min(sizeLimit*speedMultiplier,max(0,d.speed+acceleration*motionDT))
                d.position.y += d.speed*motionDT
                let gust = sin(d.age*(0.72+min(r,8)*0.045)+d.phase*1.73)
                let spatialWobble = d.wobble > 0.035 ? sin(d.position.y*0.055+d.phase)*d.wobble*0.75 : 0
                if !d.heldBySweep { d.position.x += (d.drift+gust*d.wobble+spatialWobble)*d.speed*motionDT }

                // Hysteresis: a moving bead can slow into a sticky patch, but
                // it must lose nearly all momentum before static resistance
                // takes over again. This is what creates intermittent pauses.
                if d.speed < FlowTuning.restingSpeedThreshold
                    && gravityForce+speedPulse*FlowTuning.breakawayPulseRatio
                        < staticResistance*0.97 {
                    d.speed = 0
                    d.isMoving = false
                }
            }
            if d.heldBySweep && d.speed > 65 && r > 8.5 {
                d.heldBySweep = false
                d.releasedFromSweep = true
                d.deformation = max(d.deformation,0.35)
            }
            d.deformation *= exp(-dt*5)
            // Condensation slowly grows pinned beads until retention can no longer hold them.
            d.volume += (isMist ? 0.65 : baseIntensity)*dt*r*0.15
            let delta = d.position-d.previous
            let length = sqrt(delta.x*delta.x+delta.y*delta.y)
            let blowerTrailFactor: Float = d.blowRemaining > 0
                ? min(0.35,max(0,(r-4.0)*0.12))
                : 1
            if length > 0.35 && blowerTrailFactor > 0.01 {
                // The rivulet keeps the moving drop's radius instead of using
                // one global stroke width. A lower floor keeps tiny beads
                // visible while the larger beads leave clearly wider tracks.
                let trailScale = 1+delugeBlend*(FlowTuning.delugeTrailWidthScale-1)
                let width = max(0.36,r*0.34)*trailScale*blowerTrailFactor
                let depositScale = 1+delugeBlend*(FlowTuning.delugeTrailDepositScale-1)
                let deposited = min(max(0,d.volume-0.001),length*width*0.035*depositScale*blowerTrailFactor)
                trails.append(Trail(position:d.previous,end:d.position,radius:width,
                                    life:blowerTrailFactor < 1 ? 0.45 : 1,volume:deposited))
                d.volume -= deposited
            }
            drops[i] = d
        }
        if stepCount % quality.coalescenceInterval == 0 { coalesce() }
        drops.removeAll { $0.position.y > size.y + 40 || $0.position.x < -40 || $0.position.x > size.x+40 || $0.age > 180 }
        for i in trails.indices {
            let directTrailLifetime = (5.5+baseStorm*4)
                * (1+delugeBlend*(FlowTuning.delugeTrailLifetimeScale-1))
            let lifetime: Float = trails[i].isThroughFlow
                ? 24
                : (trails[i].isRivulet ? 9 : directTrailLifetime)
            trails[i].life -= dt/lifetime
        }
        trails.removeAll { $0.life <= 0 }
        let trailLimit = min(16000,Int(Float(10000+baseStorm*6000)*quality.trailHistoryScale))
        if trails.count > trailLimit { trails.removeFirst(trails.count-trailLimit) }
    }

    /// In a downpour, small beads entering an existing direct-drop trail are
    /// absorbed into that trail instead of remaining as separate beads. This
    /// is limited to the downstream side of a segment so a drop does not
    /// absorb its own freshly deposited trail on the next frame.
    private mutating func absorbDelugeDropsIntoTrails(blend: Float) {
        guard !drops.isEmpty, !trails.isEmpty else { return }
        let cell: Float = 32
        var buckets: [SIMD2<Int32>:[Int]] = [:]
        for (index,trail) in trails.enumerated()
            where !trail.isRivulet && !trail.isThroughFlow {
            let lo = SIMD2<Int32>(
                Int32(floor(min(trail.position.x,trail.end.x)/cell)),
                Int32(floor(min(trail.position.y,trail.end.y)/cell)))
            let hi = SIMD2<Int32>(
                Int32(floor(max(trail.position.x,trail.end.x)/cell)),
                Int32(floor(max(trail.position.y,trail.end.y)/cell)))
            for x in lo.x...hi.x {
                for y in lo.y...hi.y {
                    buckets[SIMD2<Int32>(x,y),default:[]].append(index)
                }
            }
        }
        guard !buckets.isEmpty else { return }

        var remaining: [Drop] = []
        remaining.reserveCapacity(drops.count)
        for drop in drops {
            guard !drop.collected, !drop.heldBySweep,
                  drop.radius <= FlowTuning.delugeTrailCaptureMaxDropRadius,
                  drop.speed <= FlowTuning.delugeTrailCaptureMaxSpeed else {
                remaining.append(drop)
                continue
            }
            guard blend >= 1 || random() < blend else {
                remaining.append(drop)
                continue
            }
            let reach = max(1.5,drop.radius*0.35)
            let lo = SIMD2<Int32>(
                Int32(floor((drop.position.x-reach)/cell)),
                Int32(floor((drop.position.y-reach)/cell)))
            let hi = SIMD2<Int32>(
                Int32(floor((drop.position.x+reach)/cell)),
                Int32(floor((drop.position.y+reach)/cell)))
            var candidates = Set<Int>()
            for x in lo.x...hi.x {
                for y in lo.y...hi.y {
                    candidates.formUnion(buckets[SIMD2<Int32>(x,y)] ?? [])
                }
            }

            var bestIndex: Int?
            var bestDistance = Float.greatestFiniteMagnitude
            for index in candidates {
                let trail = trails[index]
                let gap = max(0.5,drop.radius*0.25)
                guard trail.end.y > drop.position.y + gap else { continue }
                let captureRadius = trail.radius*FlowTuning.delugeTrailCaptureRadiusScale
                    + drop.radius*0.35
                let distance = segmentDistance(drop.position,trail.position,trail.end)
                guard distance < captureRadius, distance < bestDistance else { continue }
                bestIndex = index
                bestDistance = distance
            }
            guard let index = bestIndex else {
                remaining.append(drop)
                continue
            }

            let trail = trails[index]
            let addedArea = drop.volume*FlowTuning.delugeTrailCaptureAreaScale
            trails[index].radius = min(FlowTuning.delugeTrailMaxRadius,
                                       sqrt(trail.radius*trail.radius+addedArea))
            trails[index].volume += drop.volume
            trails[index].life = max(trails[index].life,1)
        }
        drops = remaining
    }

    private mutating func updateRivulets(dt: Float, size: SIMD2<Float>, intensity: Float) {
        let scale = min(1, max(0, (intensity-0.35)/5.25))
        let isHeavy = intensity >= 3.8
        let isDownpour = intensity >= 5.6
        let desired: Int
        if isDownpour { desired = 12 }
        else if isHeavy { desired = 8 }
        else { desired = intensity > 0.45 ? 1 + Int(scale*5) : 0 }
        let desiredThrough: Int
        if isDownpour { desiredThrough = 2 }
        else if isHeavy { desiredThrough = 1 }
        else { desiredThrough = intensity > 0.55 ? 1 : 0 }
        var localCount = rivulets.reduce(0) { $0 + ($1.isThroughFlow ? 0 : 1) }
        var throughCount = rivulets.reduce(0) { $0 + ($1.isThroughFlow ? 1 : 0) }
        if localCount < desired || throughCount < desiredThrough {
            if rivulets.isEmpty && rivuletSpawn >= 0 { rivuletSpawn = 1 }
            rivuletSpawn += dt*(0.04+scale*0.24)
            while (localCount < desired || throughCount < desiredThrough) && rivuletSpawn >= 1 {
                rivuletSpawn -= 1
                let through = throughCount < desiredThrough
                var selected: Rivulet?
                for _ in 0..<24 {
                    let start = through
                        ? SIMD2(random()*size.x,-60-random()*40)
                        : SIMD2(random()*size.x,random()*size.y*0.78)
                    let candidate = Rivulet(position:start,
                                             baseWidth:through ? 2.2+random()*2.4 : 1.7+random()*1.4,
                                             speed:22+random()*16,
                                             phase:random()*100,
                                             drift:(random()-0.5)*0.09,
                                             wobble:0.015+random()*0.045,
                                             isThroughFlow:through,
                                             lifetime:through ? 18+random()*14 : 24,
                                             fadeDuration:through ? 8+random()*4 : 4)
                    if !through || allowsThroughFlow(candidate,size:size) {
                        selected = candidate
                        break
                    }
                }
                if let selected {
                    rivulets.append(selected)
                    if through { throughCount += 1 }
                    else { localCount += 1 }
                }
            }
        }
        var activeRivulets: [Rivulet] = []
        activeRivulets.reserveCapacity(rivulets.count)
        for var rivulet in rivulets {
            if let segment = rivulet.step(dt:dt,size:size,intensity:intensity) {
                trails.append(segment)
            }
            if rivulet.isExpired {
                // Let the next spawn happen at a different random x after a
                // short gap instead of replacing the old channel in place.
                rivuletSpawn = min(rivuletSpawn,-1.2)
                continue
            }
            if rivulet.position.y > size.y+40 {
                let startY = rivulet.isThroughFlow ? -60-random()*40 : -rivulet.width*2
                let startX = rivulet.isThroughFlow ? rivulet.position.x : random()*size.x
                rivulet.reset(at:SIMD2(startX,startY))
            }
            activeRivulets.append(rivulet)
        }
        rivulets = activeRivulets
    }

    /// Prevent full-height channels from occupying the same vertical lane.
    /// Comparing sampled centerlines catches crossings caused by the curved
    /// path, not only collisions between their starting X coordinates.
    private func allowsThroughFlow(_ candidate: Rivulet, size: SIMD2<Float>) -> Bool {
        let candidateSegments = candidate.continuousSegments(size:size)
        for existing in rivulets where existing.isThroughFlow {
            let existingSegments = existing.continuousSegments(size:size)
            for (a,b) in zip(candidateSegments,existingSegments) {
                let ac = (a.position+a.end)*0.5
                let bc = (b.position+b.end)*0.5
                let clearance = a.radius+b.radius+8
                if abs(ac.x-bc.x) < clearance { return false }
            }
        }
        return true
    }
    /// Spatial hash and swept collision tests catch beads even during a fast downward slide.
    public mutating func coalesce() {
        guard drops.count > 1 else { return }
        let cell: Float = 32
        var buckets: [SIMD2<Int32>:[Int]] = [:]
        for (i,d) in drops.enumerated() {
            let key = SIMD2<Int32>(Int32(floor(d.position.x/cell)),Int32(floor(d.position.y/cell)))
            buckets[key,default:[]].append(i)
        }
        let largest = drops.map(\.radius).max() ?? 1
        var removed = Set<Int>()
        for i in drops.indices where !removed.contains(i) {
            let a = drops[i]
            let reach = a.radius + largest
            let lo = SIMD2<Int32>(Int32(floor((min(a.position.x,a.previous.x)-reach)/cell)),Int32(floor((min(a.position.y,a.previous.y)-reach)/cell)))
            let hi = SIMD2<Int32>(Int32(floor((max(a.position.x,a.previous.x)+reach)/cell)),Int32(floor((max(a.position.y,a.previous.y)+reach)/cell)))
            for x in lo.x...hi.x { for y in lo.y...hi.y {
                for j in buckets[SIMD2(x,y)] ?? [] where j > i && !removed.contains(j) {
                    let b = drops[j]
                    let distance = segmentDistance(.zero,drops[i].previous-b.previous,drops[i].position-b.position)
                    guard distance < (drops[i].radius+b.radius)*0.83 else { continue }
                    let va = drops[i].volume, vb = b.volume, total = va+vb
                    drops[i].position = (drops[i].position*va+b.position*vb)/total
                    drops[i].speed = (drops[i].speed*va+b.speed*vb)/total
                    drops[i].speedFactor = (drops[i].speedFactor*va+b.speedFactor*vb)/total
                    drops[i].drift = (drops[i].drift*va+b.drift*vb)/total
                    drops[i].wobble = (drops[i].wobble*va+b.wobble*vb)/total
                    drops[i].isMoving = drops[i].isMoving || b.isMoving
                    drops[i].volume = total
                    drops[i].collected = drops[i].collected || b.collected
                    drops[i].heldBySweep = drops[i].heldBySweep || b.heldBySweep
                    drops[i].releasedFromSweep = drops[i].releasedFromSweep || b.releasedFromSweep
                    drops[i].deformation = min(0.55,drops[i].deformation + vb/total)
                    drops[i].age = min(drops[i].age,b.age)
                    removed.insert(j); mergerCount += 1
                }
            }}
        }
        drops = drops.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element }
    }
}
