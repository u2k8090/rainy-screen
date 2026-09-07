import Foundation

/// A one-dimensional finite-volume strip along the moving contact boundary.
/// Each cell owns its water; all fluxes and detached beads subtract that water.
public struct SweepRidge {
    public static let spacing: Float = 8
    public private(set) var volumes: [Float] = []
    public private(set) var x: Float = 0
    public private(set) var vertical = false
    public var totalVolume: Float { volumes.reduce(0,+) }

    public mutating func collect(volume: Float, y: Float, radius: Float, x: Float) {
        collect(volume:volume,coordinate:y,radius:radius,boundary:x)
    }

    public mutating func configure(vertical: Bool) {
        guard self.vertical != vertical else { return }
        self.vertical = vertical
        volumes.removeAll()
    }

    public mutating func collect(volume: Float, coordinate: Float, radius: Float, boundary: Float) {
        guard volume > 0 else { return }
        self.x = boundary
        let center = max(0,Int(coordinate/Self.spacing))
        let reach = max(1,Int(ceil(radius/Self.spacing)))
        let lo = max(0,center-reach), hi = center+reach
        if volumes.count <= hi+1 { volumes += Array(repeating:0,count:hi+2-volumes.count) }
        var weights: [Float] = []
        for i in lo...hi {
            let distance = (Float(i)+0.5)*Self.spacing-coordinate
            weights.append(exp(-distance*distance/(2*max(4,radius)*max(4,radius))))
        }
        let sum = weights.reduce(0,+)
        for (offset,weight) in weights.enumerated() { volumes[lo+offset] += volume*weight/sum }
    }

    public mutating func move(to x: Float) { self.x = x }

    /// Width follows local cross-sectional area, rather than a global stroke size.
    public func width(at index: Int) -> Float {
        guard volumes.indices.contains(index) else { return 0 }
        return sqrt(max(0,volumes[index])/(Self.spacing*0.12))
    }

    /// Width used for the visible contact ridge. Surface tension joins nearby
    /// cells into one liquid front without changing the conserved simulation
    /// volumes. The center cell remains dominant so large pooled bulges keep
    /// their shape instead of becoming a uniform strip.
    public func pooledWidth(at index: Int) -> Float {
        guard volumes.indices.contains(index) else { return 0 }
        let left2 = index > 1 ? volumes[index-2] : 0
        let left = index > 0 ? volumes[index-1] : 0
        let center = volumes[index]
        let right = index+1 < volumes.count ? volumes[index+1] : 0
        let right2 = index+2 < volumes.count ? volumes[index+2] : 0
        let pooled = left2*0.08 + left*0.18 + center*0.48 + right*0.18 + right2*0.08
        return sqrt(max(0,pooled)/(Self.spacing*0.12))
    }

    public mutating func step(dt: Float, height: Float) -> [Drop] {
        guard dt > 0, volumes.count > 1 else { return [] }
        var released: [Drop] = []
        // Substeps bound each outgoing flux by the water actually in its cell.
        let steps = max(1,Int(ceil(dt/0.008)))
        let delta = dt/Float(steps)
        for _ in 0..<steps {
            let old = volumes
            for i in 0..<old.count-1 {
                let width = sqrt(max(0,old[i])/(Self.spacing*0.12))
                // Small contact patches remain pinned. Deep bulges drain faster.
                let velocity = max(0,width-5)*1.5
                let gravityFlux = min(old[i]*0.45,old[i]*velocity*delta/Self.spacing)
                volumes[i] -= gravityFlux; volumes[i+1] += gravityFlux
                // A narrow bridge has greater transverse curvature than its
                // neighbouring bulge. Drain that bridge into the bulge; retain
                // weak smoothing for subpixel patches. This reduced model is
                // bounded by donor volume rather than adding decorative noise.
                let upper = (old[max(0,i-1)]+2*old[i]+old[i+1])*0.25
                let lower = (old[i]+2*old[i+1]+old[min(old.count-1,i+2)])*0.25
                let difference = upper-lower
                let pooling = max(old[i],old[i+1]) > 60
                // Long-wave pooling with short-wave smoothing avoids a
                // cell-sized sawtooth instability in the free boundary.
                let rate = (pooling ? difference*3 : 0)-(old[i]-old[i+1])*0.85
                let donor = rate > 0 ? old[i+1] : old[i]
                let exchange = min(abs(rate)*delta,donor*0.12)
                if rate > 0 { volumes[i] += exchange; volumes[i+1] -= exchange }
                else { volumes[i] -= exchange; volumes[i+1] += exchange }
            }
        }
        // Detach a heavy lower bulge only when its upstream neck is narrow.
        for i in 1..<volumes.count-1 {
            let width = self.width(at:i)
            let neck = self.width(at:i-1)
            guard width > 24, neck < width*0.35, volumes[i] > volumes[i+1] else { continue }
            let amount = volumes[i]*0.72
            volumes[i] -= amount
            let coordinate = (Float(i)+0.5)*Self.spacing
            let position = vertical
                ? SIMD2(coordinate,x+width*0.5)
                : SIMD2(x+width*0.5,coordinate)
            var bead = Drop(position:position,
                            radius:pow(amount,1/3),speed:110)
            bead.collected = true; bead.releasedFromSweep = true
            bead.deformation = 0.4
            released.append(bead)
        }
        for i in volumes.indices where Float(i)*Self.spacing > height+40 {
            volumes[i] = 0 // outflow beyond the display
        }
        if let last = volumes.last, last > 0.01, Float(volumes.count)*Self.spacing < height+40 {
            volumes.append(0)
        }
        return released
    }

    public mutating func releaseAll() -> [Drop] {
        var result: [Drop] = []
        // Preserve local variation when the contact boundary leaves the pane.
        for i in volumes.indices where volumes[i] > 0.001 {
            let coordinate = (Float(i)+0.5)*Self.spacing
            let position = vertical ? SIMD2(coordinate,x) : SIMD2(x,coordinate)
            var bead = Drop(position:position,
                            radius:pow(volumes[i],1/3),speed:100)
            bead.collected = true; bead.releasedFromSweep = true
            result.append(bead)
        }
        volumes.removeAll()
        return result
    }
}
