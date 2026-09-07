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
            isRaining ? Float(min(1.5, max(0.25, (rain + showers) * 1.5 + 0.3))) : 0
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
        let isMist = intensity > 0.001 && (mist || intensity <= 0.5)
        let speedMultiplier: Float = isDeluge ? 1.35 : (isMist ? 0.18 : 1)
        let dropLimit = isMist ? 3200 : Int(1800 + baseStorm*1800)
        let spawnRate = isMist ? 11.5 : min(8.4,baseIntensity)
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
                running = random() < 0.035+baseStorm*0.12
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
        for i in drops.indices {
            var d = drops[i]
            d.previous = d.position; d.age += dt
            d.stallCooldown = max(0,d.stallCooldown-dt)
            var stalled = false
            if d.stallTimer > 0 {
                d.stallTimer = max(0,d.stallTimer-dt)
                d.speed *= exp(-dt*16)
                stalled = true
                if d.stallTimer == 0 { d.speed = max(8,d.speed) }
            } else if d.stallCooldown == 0 && d.stallTendency > 0 && d.speed > 24,
                      random() < dt*(0.045+0.14*d.stallTendency) {
                d.stallTimer = 0.28+random()*(0.5+1.0*d.stallTendency)
                d.stallCooldown = 0.9+random()*2.4
                d.speed *= 0.12
                stalled = true
                stallCount += 1
            }
            // Give released sweep water a brisk runoff without speeding up
            // ambient rain or changing the contact-boundary accumulation.
            let motionDT = dt * (d.collected && d.releasedFromSweep ? 1.8 : 1)
            let r = d.radius
            // Gravity scales with volume; contact-line retention scales with radius.
            // A spatial adhesion field plus different static/kinetic thresholds produces stick-slip.
            let patch = 1 + 0.38*sin(d.position.y*0.055+d.phase)
                + 0.18*sin(d.position.y*0.19+d.phase*2)
                + 0.06*sin(d.position.x*0.017+d.phase*0.73)
            let glassRetention = 460 * pow(3.35/r,2) * d.adhesion * patch
            let retention = d.heldBySweep ? max(glassRetention,460*pow(8.5/r,2)) : glassRetention
            let resistance = d.speed > 3 ? retention*0.55 : retention
            if !stalled && (d.speed > 0 || resistance < 460) {
                let sizeFactor = 0.72 + min(1.0,max(0,r-1)/6.0)*0.88
                let cadence = 0.48 + min(1.6,d.speedFactor)*0.33 + min(r,8)*0.035
                let speedPulse = sin(d.age*cadence+d.phase*1.37)*(28+min(r,8)*5)
                    + sin(d.age*(cadence*0.43+0.17)-d.phase*0.61)*14
                let acceleration = ((460 - resistance - d.speed*10/max(r,1)
                                    - d.speed*d.speed/(max(r,1)*90)) + speedPulse)
                    * speedMultiplier * sizeFactor * d.speedFactor
                let sizeLimit = (320 + min(330,r*52))*d.speedFactor
                d.speed = min(sizeLimit*speedMultiplier,max(0,d.speed+acceleration*motionDT))
                d.position.y += d.speed*motionDT
                let gust = sin(d.age*(0.72+min(r,8)*0.045)+d.phase*1.73)
                let spatialWobble = d.wobble > 0.035 ? sin(d.position.y*0.055+d.phase)*d.wobble*0.75 : 0
                if !d.heldBySweep { d.position.x += (d.drift+gust*d.wobble+spatialWobble)*d.speed*motionDT }
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
            if length > 0.35 {
                // The rivulet keeps the moving drop's radius instead of using
                // one global stroke width. A lower floor keeps tiny beads
                // visible while the larger beads leave clearly wider tracks.
                let width = max(0.36,r*0.34)
                let deposited = min(max(0,d.volume-0.001),length*width*0.035)
                trails.append(Trail(position:d.previous,end:d.position,radius:width,life:1,volume:deposited))
                d.volume -= deposited
            }
            drops[i] = d
        }
        if stepCount % quality.coalescenceInterval == 0 { coalesce() }
        drops.removeAll { $0.position.y > size.y + 40 || $0.position.x < -40 || $0.position.x > size.x+40 || $0.age > 180 }
        for i in trails.indices {
            let lifetime: Float = trails[i].isThroughFlow
                ? 24
                : (trails[i].isRivulet ? 9 : 5.5+baseStorm*4)
            trails[i].life -= dt/lifetime
        }
        trails.removeAll { $0.life <= 0 }
        let trailLimit = min(16000,Int(Float(10000+baseStorm*6000)*quality.trailHistoryScale))
        if trails.count > trailLimit { trails.removeFirst(trails.count-trailLimit) }
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
