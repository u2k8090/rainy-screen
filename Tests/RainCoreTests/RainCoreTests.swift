import XCTest
@testable import RainCore

final class RainCoreTests: XCTestCase {
    private func weather(code:Int,rain:Double = 0,showers:Double = 0,age:Double = 0) throws -> WeatherResponse.Current {
        let json = "{\"current\":{\"time\":\(Date().timeIntervalSince1970-age),\"rain\":\(rain),\"showers\":\(showers),\"weather_code\":\(code)}}"
        return try JSONDecoder().decode(WeatherResponse.self,from:Data(json.utf8)).current
    }
    func testRainSnowAndDryWeather() throws {
        for code in [51,53,55,56,57,61,63,65,66,67,80,81,82,95,96,99] {
            XCTAssertTrue(try weather(code:code).isRaining)
        }
        for code in [0,1,2,3,45,48,71,73,75,77,85,86] {
            XCTAssertFalse(try weather(code:code).isRaining)
        }
        XCTAssertTrue(try weather(code:3,rain:0.1).isRaining)
        XCTAssertTrue(try weather(code:3,showers:0.1).isRaining)
        XCTAssertEqual(try weather(code:0).intensity,0)
    }

    func testWeatherRainIntensityUsesCodeAndRecentAmount() throws {
        XCTAssertEqual(try weather(code:61).intensity,0.8)
        XCTAssertEqual(try weather(code:63).intensity,1.4)
        XCTAssertEqual(try weather(code:65).intensity,3.8)
        XCTAssertEqual(try weather(code:82).intensity,5.6)

        let lightAmount = try weather(code:61,rain:0.1).intensity
        let heavierAmount = try weather(code:61,rain:1).intensity
        XCTAssertGreaterThan(heavierAmount,lightAmount)
        XCTAssertLessThanOrEqual(try weather(code:61,rain:100).intensity,5.6)
    }
    func testRejectsStaleAndFutureWeather() throws {
        XCTAssertTrue(try weather(code:61,age:900).isFresh(at:Date()))
        XCTAssertFalse(try weather(code:61,age:1900).isFresh(at:Date()))
        XCTAssertFalse(try weather(code:61,age:-600).isFresh(at:Date()))
    }
    func testWipeUsesWholeSegmentNotOnlyCursorEndpoints() {
        XCTAssertEqual(segmentDistance(SIMD2(50,4),SIMD2(0,0),SIMD2(100,0)),4,accuracy:0.001)
        XCTAssertEqual(segmentDistance(SIMD2(3,4),.zero,.zero),5,accuracy:0.001)
        var model = RainModel()
        for _ in 0..<120 { model.step(dt:1/30,size:SIMD2(500,500),intensity:1) }
        XCTAssertFalse(model.drops.isEmpty)
        model.wipe(from:SIMD2(0,250),to:SIMD2(500,250),radius:1000)
        XCTAssertTrue(model.drops.isEmpty)
        XCTAssertTrue(model.trails.isEmpty)
    }

    func testBlowerAddsRadialImpulseWithFiniteTravelWithoutDeletingWater() {
        var model = RainModel()
        model.add(Drop(position: SIMD2(180,100), radius: 3))
        model.add(Drop(position: SIMD2(100,180), radius: 3))
        model.blow(at: SIMD2(100,100), radius: 120, strength: .standard)
        XCTAssertEqual(model.drops.count, 2)
        XCTAssertGreaterThan(model.drops[0].blowVelocity.x, 0)
        XCTAssertGreaterThan(model.drops[1].blowVelocity.y, 0)
        let before = model.drops[0].position
        model.step(dt: 1/30, size: SIMD2(800,600), intensity: 0)
        XCTAssertGreaterThan(model.drops[0].position.x, before.x)
        XCTAssertGreaterThan(model.drops[0].blowRemaining, 0)
        XCTAssertTrue(model.trails.isEmpty, "小さな吹き飛ばし中の滴は筋を残さず粒で飛ぶ")
        for _ in 0..<240 { model.step(dt: 1/30, size: SIMD2(800,600), intensity: 0) }
        XCTAssertEqual(model.drops.first?.blowRemaining ?? 0, 0, accuracy: 0.001)

        var large = RainModel()
        large.add(Drop(position: SIMD2(180,100), radius: 6))
        large.blow(at: SIMD2(100,100), radius: 120, strength: .standard)
        large.step(dt: 1/30, size: SIMD2(800,600), intensity: 0)
        XCTAssertFalse(large.trails.isEmpty, "大きな滴は吹き飛ばし中も薄い筋を残す")
    }

    func testBlowerStrengthExpandsItsAffectedArea() {
        var minimum = RainModel()
        var standard = RainModel()
        let edge = SIMD2<Float>(220,100)
        minimum.add(Drop(position:edge,radius:3))
        standard.add(Drop(position:edge,radius:3))
        let center = SIMD2<Float>(100,100)
        minimum.blow(at:center, radius:100*BlowerStrength.verySoft.radiusMultiplier,
                     strength:.verySoft)
        standard.blow(at:center, radius:100*BlowerStrength.standard.radiusMultiplier,
                      strength:.standard)
        XCTAssertEqual(minimum.drops[0].blowVelocity,.zero)
        XCTAssertGreaterThan(standard.drops[0].blowVelocity.x,0)
    }

    func testBlowerDoesNotSlideThroughFlowChannels() {
        var model = RainModel()
        for _ in 0..<600 { model.step(dt: 1/30, size: SIMD2(1000,800), intensity: 5.6) }
        guard let index = model.rivulets.firstIndex(where: { $0.isThroughFlow }) else {
            XCTFail("豪雨のthrough-flowが生成されていない")
            return
        }
        let before = model.rivulets[index].position
        model.blow(at: before, radius: 240, strength: .veryStrong)
        XCTAssertEqual(model.rivulets[index].position, before,
                       "through-flow水路はブロワーで横滑りしない")
    }
    func testGrowthBoundsClearAndDry() {
        var model = RainModel()
        model.step(dt:1/30,size:SIMD2(1000,800),intensity:0)
        XCTAssertTrue(model.drops.isEmpty)
        for _ in 0..<1800 { model.step(dt:1/30,size:SIMD2(1000,800),intensity:1.5) }
        XCTAssertLessThanOrEqual(model.drops.count,1800)
        XCTAssertLessThanOrEqual(model.trails.count,10000)
        XCTAssertTrue(model.drops.contains {$0.speed > 0}, "Rain must keep moving after long use")
        XCTAssertTrue(model.drops.allSatisfy {$0.position.y <= 840})
        model.clear()
        XCTAssertTrue(model.drops.isEmpty); XCTAssertTrue(model.trails.isEmpty)
        XCTAssertEqual(model.elapsed,0)
    }
    func testRainArrivesAcrossGlassAndDeltaTimeIsBounded() {
        var model = RainModel()
        model.step(dt:100,size:SIMD2(1000,800),intensity:1)
        XCTAssertLessThanOrEqual(model.elapsed,0.05)
        for _ in 0..<30 { model.step(dt:1/30,size:SIMD2(1000,800),intensity:1) }
        XCTAssertTrue(model.drops.contains {$0.position.y > 500})
        XCTAssertTrue(model.drops.contains {$0.position.y < 250})
        XCTAssertTrue(model.drops.contains {$0.speed == 0})
    }
    func testCoalescenceConservesVolumeAndMomentum() {
        var model = RainModel()
        model.add(Drop(position:SIMD2(100,100),radius:3,speed:20))
        model.add(Drop(position:SIMD2(103,100),radius:2,speed:80))
        model.coalesce()
        XCTAssertEqual(model.drops.count,1)
        XCTAssertEqual(model.drops[0].volume,35,accuracy:0.0001)
        XCTAssertEqual(model.drops[0].speed,(27*20+8*80)/35,accuracy:0.001)
        XCTAssertEqual(model.mergerCount,1)
        XCTAssertGreaterThan(model.drops[0].deformation,0)
    }
    func testPinnedDropsReleaseAfterCoalescence() {
        var single = RainModel()
        single.add(Drop(position:SIMD2(100,0),radius:2.8))
        single.step(dt:1/30,size:SIMD2(500,500),intensity:0)
        XCTAssertEqual(single.drops[0].speed,0)
        var merged = RainModel()
        merged.add(Drop(position:SIMD2(100,0),radius:2.8))
        merged.add(Drop(position:SIMD2(103,0),radius:2.8))
        merged.coalesce()
        for _ in 0..<12 { merged.step(dt:1/30,size:SIMD2(500,500),intensity:0) }
        XCTAssertGreaterThan(merged.drops[0].speed,10)
        XCTAssertGreaterThan(merged.drops[0].position.y,0)
    }
    func testSweptCollisionDoesNotTunnelThroughSmallBead() {
        var model = RainModel()
        var moving = Drop(position:SIMD2(100,115),radius:4,speed:300)
        moving.previous = SIMD2(100,90)
        model.add(moving)
        model.add(Drop(position:SIMD2(100,100),radius:1))
        model.coalesce()
        XCTAssertEqual(model.drops.count,1)
        XCTAssertEqual(model.drops[0].volume,65,accuracy:0.0001)
    }
    func testGravityAcceleratesLargeDropsAndLeavesRivulets() {
        var model = RainModel()
        model.add(Drop(position:SIMD2(100,0),radius:6))
        model.step(dt:1/30,size:SIMD2(500,1000),intensity:0)
        let first = model.drops[0].speed
        for _ in 0..<30 { model.step(dt:1/30,size:SIMD2(500,1000),intensity:0) }
        XCTAssertGreaterThan(model.drops[0].speed,first+50)
        XCTAssertFalse(model.trails.isEmpty)
    }

    func testRenderQualityControlsCollisionCadence() {
        XCTAssertEqual(RainRenderQuality.high.coalescenceInterval,1)
        XCTAssertEqual(RainRenderQuality.balanced.coalescenceInterval,2)
        XCTAssertEqual(RainRenderQuality.light.coalescenceInterval,3)

        var high = RainModel()
        high.add(Drop(position:SIMD2(100,100),radius:3))
        high.add(Drop(position:SIMD2(103,100),radius:3))
        high.step(dt:1/30,size:SIMD2(500,500),intensity:0,quality:.high)
        XCTAssertEqual(high.drops.count,1)

        var balanced = RainModel()
        balanced.add(Drop(position:SIMD2(100,100),radius:3))
        balanced.add(Drop(position:SIMD2(103,100),radius:3))
        balanced.step(dt:1/30,size:SIMD2(500,500),intensity:0,quality:.balanced)
        XCTAssertEqual(balanced.drops.count,2)
        balanced.step(dt:1/30,size:SIMD2(500,500),intensity:0,quality:.balanced)
        XCTAssertEqual(balanced.drops.count,1)
    }

    func testRivuletGetsFasterDownstreamAsVolumeAccumulates() {
        var upper = Rivulet(position:SIMD2(200,40),baseWidth:3,speed:24,
                            phase:1.2,drift:0,wobble:0.02,isThroughFlow:true)
        var lower = Rivulet(position:SIMD2(200,720),baseWidth:3,speed:24,
                            phase:1.2,drift:0,wobble:0.02,isThroughFlow:true)
        _ = upper.step(dt:1/30,size:SIMD2(1000,800),intensity:5.6)
        _ = lower.step(dt:1/30,size:SIMD2(1000,800),intensity:5.6)
        XCTAssertGreaterThan(lower.speed,upper.speed,
                             "下流側は集積した水量によって上流側より速くなる")
    }

    func testSweepTransfersWaterIntoVariableWidthRidge() {
        var model = RainModel()
        for i in 0..<32 { model.add(Drop(position:SIMD2(Float(i)*20+10,120),radius:3)) }
        let volume = model.drops.reduce(0) { $0+$1.volume }
        model.sweep(from:0,to:650)
        XCTAssertTrue(model.drops.isEmpty)
        XCTAssertEqual(model.ridge.totalVolume,volume,accuracy:0.01)
        let widths = model.ridge.volumes.indices.map { model.ridge.width(at:$0) }
        XCTAssertGreaterThan(widths.max() ?? 0,10)
        XCTAssertGreaterThan((widths.max() ?? 0)-(widths.min() ?? 0),8)
        for _ in 0..<24 { model.step(dt:1/30,size:SIMD2(1000,2000),intensity:0) }
        let remaining = model.ridge.totalVolume + model.drops.reduce(0) { $0+$1.volume }
            + model.trails.reduce(0) { $0+$1.volume }
        XCTAssertEqual(remaining,volume,accuracy:0.1)
        model.endSweep()
        XCTAssertFalse(model.drops.isEmpty)
        XCTAssertEqual(model.ridge.totalVolume,0)
    }

    func testSweepLeavesUntouchedWaterAndRidgeFluxConservesVolume() {
        var model = RainModel()
        model.add(Drop(position:SIMD2(10,100),radius:2))
        model.add(Drop(position:SIMD2(300,100),radius:2))
        model.sweep(from:0,to:50)
        XCTAssertEqual(model.ridge.totalVolume,8,accuracy:0.001)
        XCTAssertTrue(model.drops.contains { $0.position == SIMD2(300,100) })
        var ridge = SweepRidge()
        ridge.collect(volume:8000,y:160,radius:12,x:100)
        var detached: Float = 0
        for _ in 0..<120 {
            detached += ridge.step(dt:1/60,height:2000).reduce(0) { $0+$1.volume }
            XCTAssertTrue(ridge.volumes.allSatisfy { $0 >= 0 && $0.isFinite })
        }
        XCTAssertEqual(ridge.totalVolume+detached,8000,accuracy:0.2)
    }

    func testRainSpeedVariesPerDropAndLargerDropWins() {
        var rain = RainModel(seed:42)
        for _ in 0..<90 { rain.step(dt:1/30,size:SIMD2(1000,800),intensity:1.4) }
        let factors = rain.drops.map(\.speedFactor)
        XCTAssertGreaterThan(factors.max() ?? 0, (factors.min() ?? 0)+0.1)

        var sizeTest = RainModel()
        sizeTest.add(Drop(position:SIMD2(100,0),radius:2,adhesion:0.55,speedFactor:1))
        sizeTest.add(Drop(position:SIMD2(400,0),radius:6,adhesion:0.55,speedFactor:1))
        for _ in 0..<30 { sizeTest.step(dt:1/30,size:SIMD2(800,800),intensity:0) }
        XCTAssertGreaterThan(sizeTest.drops[1].speed,sizeTest.drops[0].speed)
    }

    func testStaticAndKineticResistanceCreateBreakawayHysteresis() {
        var resting = RainModel()
        resting.add(Drop(position:SIMD2(100,0),radius:3.2,phase:0,
                          adhesion:1,speedFactor:1))
        resting.step(dt:1/30,size:SIMD2(500,500),intensity:2.4)
        XCTAssertFalse(resting.drops[0].isMoving)
        XCTAssertEqual(resting.drops[0].speed,0)

        var moving = RainModel()
        moving.add(Drop(position:SIMD2(100,0),radius:3.2,speed:9,phase:0,
                        adhesion:1,speedFactor:1))
        moving.step(dt:1/30,size:SIMD2(500,500),intensity:2.4)
        XCTAssertTrue(moving.drops[0].isMoving)
        XCTAssertGreaterThan(moving.drops[0].speed,9)
        XCTAssertGreaterThan(moving.drops[0].position.y,0)
    }

    func testStrongRainCanStopAFlowingDropMoreThanOnce() {
        var rain = RainModel(seed:42)
        rain.add(Drop(position:SIMD2(50,0),radius:5,speed:80,phase:0,
                      adhesion:1,speedFactor:1,stallTendency:1))
        for _ in 0..<300 {
            rain.step(dt:1/30,size:SIMD2(100,10000),intensity:2.4)
        }
        XCTAssertGreaterThanOrEqual(rain.stallCount,2)
    }

    func testLightRainHasFewerFlowingDropsThanStrongRain() {
        var light = RainModel(seed:42), strong = RainModel(seed:42)
        for _ in 0..<180 {
            light.step(dt:1/30,size:SIMD2(320,800),intensity:0.8)
            strong.step(dt:1/30,size:SIMD2(320,800),intensity:2.4)
        }
        let lightMoving = light.drops.filter { $0.speed > 0 }.count
        let strongMoving = strong.drops.filter { $0.speed > 0 }.count
        XCTAssertGreaterThan(strongMoving,lightMoving)
    }

    func testLargeDropInLightRainKeepsStrongRunoffSpeed() {
        var light = RainModel(), strong = RainModel()
        let drop = Drop(position:SIMD2(100,0),radius:4.5,phase:0,
                        adhesion:1,speedFactor:1)
        light.add(drop); strong.add(drop)
        light.step(dt:1/30,size:SIMD2(500,500),intensity:0.35)
        strong.step(dt:1/30,size:SIMD2(500,500),intensity:2.4)
        XCTAssertEqual(light.drops[0].speed,strong.drops[0].speed,accuracy:4)
    }

    func testDownpourFavorsFastFlowingDrops() {
        var strong = RainModel(seed:42), downpour = RainModel(seed:42)
        var strongPeak: Float = 0
        var downpourPeak: Float = 0
        for _ in 0..<90 {
            strong.step(dt:1/30,size:SIMD2(320,800),intensity:2.4)
            downpour.step(dt:1/30,size:SIMD2(320,800),intensity:5.6)
            strongPeak = max(strongPeak,strong.drops.map { $0.speed }.max() ?? 0)
            downpourPeak = max(downpourPeak,downpour.drops.map { $0.speed }.max() ?? 0)
        }
        let strongFast = strong.drops.filter { $0.speed > 160 }.count
        let downpourFast = downpour.drops.filter { $0.speed > 160 }.count
        XCTAssertGreaterThan(downpourFast,strongFast)
        XCTAssertGreaterThan(downpourPeak,strongPeak*1.1)
    }

    func testDownpourLeavesLongerWiderDirectDropTrails() {
        var heavy = RainModel(), downpour = RainModel()
        let drop = Drop(position:SIMD2(100,0),radius:6,speed:150,phase:0,
                        adhesion:1,speedFactor:1)
        heavy.add(drop); downpour.add(drop)
        heavy.step(dt:1/30,size:SIMD2(500,500),intensity:3.8)
        downpour.step(dt:1/30,size:SIMD2(500,500),intensity:5.6)
        let heavyTrail = heavy.trails.first { !$0.isRivulet }
        let downpourTrail = downpour.trails.first { !$0.isRivulet }
        XCTAssertNotNil(heavyTrail)
        XCTAssertNotNil(downpourTrail)
        XCTAssertGreaterThan(downpourTrail?.radius ?? 0,heavyTrail?.radius ?? 0)
        XCTAssertGreaterThan(downpourTrail?.life ?? 0,heavyTrail?.life ?? 0)
    }

    func testHeavyBlendsStrongAndDownpourSpeedTiers() {
        var strong = RainModel(), heavy = RainModel(), downpour = RainModel()
        let drop = Drop(position:SIMD2(0.5,100),radius:6,speed:150,phase:0,
                        adhesion:1,speedFactor:1)
        strong.add(drop); heavy.add(drop); downpour.add(drop)
        let size = SIMD2<Float>(1,500)
        strong.step(dt:1/30,size:size,intensity:2.4)
        heavy.step(dt:1/30,size:size,intensity:3.8)
        downpour.step(dt:1/30,size:size,intensity:5.6)

        XCTAssertGreaterThan(heavy.drops[0].speed,strong.drops[0].speed)
        XCTAssertLessThan(heavy.drops[0].speed,downpour.drops[0].speed)
    }

    func testDownpourAbsorbsSmallDropsIntoDownstreamDirectTrail() {
        var model = RainModel()
        model.add(Drop(position:SIMD2(0.5,100),radius:6,speed:150,phase:0,
                       adhesion:1,speedFactor:1))
        model.step(dt:1/30,size:SIMD2(1,500),intensity:5.6)
        let initialTrail = model.trails.first { !$0.isRivulet }
        XCTAssertNotNil(initialTrail)

        model.add(Drop(position:SIMD2(0.5,101),radius:2,speed:0,phase:0,
                       adhesion:1,speedFactor:1))
        model.step(dt:1/30,size:SIMD2(1,500),intensity:5.6)

        let updatedTrail = model.trails.first { !$0.isRivulet }
        XCTAssertGreaterThan(updatedTrail?.radius ?? 0,initialTrail?.radius ?? 0)
        XCTAssertEqual(model.drops.count,1)
    }

    func testRainUsesMixedStraightAndMeanderingTrajectories() {
        var rain = RainModel(seed:42)
        for _ in 0..<180 { rain.step(dt:1/30,size:SIMD2(1000,800),intensity:3.8) }
        XCTAssertTrue(rain.drops.contains { abs($0.drift) < 0.02 && $0.wobble < 0.02 },
                      "大雨にはほぼ垂直に落ちる粒を含める")
        XCTAssertTrue(rain.drops.contains { abs($0.drift) > 0.035 && $0.wobble < 0.04 },
                      "大雨には一定角度の斜め軌跡を含める")
        XCTAssertTrue(rain.drops.contains { $0.wobble > 0.04 },
                      "大雨には蛇行する軌跡も残す")
    }

    func testRivuletsStartSparseAndScaleWithRain() {
        var light = RainModel(seed:42), heavy = RainModel(seed:42), deluge = RainModel(seed:42)
        for _ in 0..<600 {
            light.step(dt:1/30,size:SIMD2(1000,800),intensity:0.8)
            heavy.step(dt:1/30,size:SIMD2(1000,800),intensity:3.8)
            deluge.step(dt:1/30,size:SIMD2(1000,800),intensity:5.6)
        }
        XCTAssertGreaterThanOrEqual(light.rivulets.count,1)
        XCTAssertLessThanOrEqual(light.rivulets.count,2)
        XCTAssertGreaterThan(heavy.rivulets.count,light.rivulets.count)
        XCTAssertGreaterThan(deluge.rivulets.count,heavy.rivulets.count)
        XCTAssertGreaterThan(deluge.rivulets.map(\.width).max() ?? 0,
                             heavy.rivulets.map(\.width).max() ?? 0)
        XCTAssertGreaterThan(deluge.rivulets.map(\.speed).max() ?? 0,
                             heavy.rivulets.map(\.speed).max() ?? 0)
        XCTAssertTrue(deluge.trails.contains { $0.isRivulet })
        XCTAssertTrue(deluge.rivulets.contains { $0.isThroughFlow })
        XCTAssertGreaterThan(deluge.stallCount,0)
        XCTAssertLessThanOrEqual(heavy.rivulets.filter { $0.isThroughFlow }.count,1)
        XCTAssertLessThanOrEqual(deluge.rivulets.filter { $0.isThroughFlow }.count,2)

        let activeFlows = deluge.rivulets.filter { $0.isThroughFlow }
        if activeFlows.count == 2 {
            let left = activeFlows[0].continuousSegments(size:SIMD2(1000,800))
            let right = activeFlows[1].continuousSegments(size:SIMD2(1000,800))
            for (a,b) in zip(left,right) {
                let ac = (a.position+a.end)*0.5
                let bc = (b.position+b.end)*0.5
                XCTAssertGreaterThanOrEqual(abs(ac.x-bc.x),a.radius+b.radius+8)
            }
        }

        var flow = Rivulet(position:SIMD2(200,-40),baseWidth:3,speed:30,
                           phase:1,drift:0,wobble:0,isThroughFlow:true,
                           lifetime:30,fadeDuration:4,birthDuration:0)
        _ = flow.step(dt:1/30,size:SIMD2(1000,800),intensity:5.6)
        let segments = flow.continuousSegments(size:SIMD2(1000,800))
        XCTAssertGreaterThan(segments.map { $0.radius }.max() ?? 0,
                             (segments.map { $0.radius }.min() ?? 0)*1.25)
        XCTAssertGreaterThan(segments.map { ($0.position.x+$0.end.x)*0.5 }.max() ?? 0,
                             (segments.map { ($0.position.x+$0.end.x)*0.5 }.min() ?? 0) + 20)

        let originalAnchor = flow.anchorX
        let originalAge = flow.age
        flow.reset(at:SIMD2(420,-60))
        XCTAssertEqual(flow.anchorX,originalAnchor)
        XCTAssertEqual(flow.age,originalAge,accuracy:0.0001)

        var fading = Rivulet(position:SIMD2(200,-40),baseWidth:3,speed:30,
                             phase:1,drift:0,wobble:0,isThroughFlow:true,
                             lifetime:2,fadeDuration:0.5,birthDuration:0)
        for _ in 0..<50 { _ = fading.step(dt:1/30,size:SIMD2(500,800),intensity:5.6) }
        let fadingSegments = fading.continuousSegments(size:SIMD2(500,800))
        XCTAssertFalse(fadingSegments.isEmpty)
        XCTAssertLessThan(fadingSegments.first?.life ?? 1,1)
        for _ in 0..<25 { _ = fading.step(dt:1/30,size:SIMD2(500,800),intensity:5.6) }
        XCTAssertLessThan(fading.width,1)
        XCTAssertTrue(fading.isExpired)
    }

    func testThroughFlowHasConnectedTaperedBends() {
        var flow = Rivulet(position: SIMD2(200,-40),baseWidth:8,speed:100,
                           phase:1,drift:0,wobble:0,isThroughFlow:true,
                           lifetime:30,birthDuration:0)
        _ = flow.step(dt:1/30,size:SIMD2(1000,800),intensity:5.6)
        let segments = flow.continuousSegments(size:SIMD2(1000,800))
        XCTAssertEqual(segments.first?.position.y,0)
        XCTAssertEqual(segments.last?.end.y,800)
        for (a,b) in zip(segments,segments.dropFirst()) {
            XCTAssertEqual(a.end,b.position)
            XCTAssertEqual(a.endRadius,b.radius)
            XCTAssertLessThanOrEqual(a.end.y-a.position.y,8.01)
            let da = a.end-a.position, db = b.end-b.position
            let bend = abs(atan2(da.x,da.y)-atan2(db.x,db.y))
            XCTAssertLessThan(bend,0.06,"Channel samples must not form visible corners")
        }
        XCTAssertTrue(segments.contains { abs(($0.endRadius ?? $0.radius)-$0.radius) > 0.01 })
    }

    func testDownpourAddsMoreWaterAndStaysBounded() {
        var medium = RainModel(seed:42), storm = RainModel(seed:42)
        for _ in 0..<60 {
            medium.step(dt:1/30,size:SIMD2(1000,800),intensity:1.4)
            storm.step(dt:1/30,size:SIMD2(1000,800),intensity:5.6)
        }
        XCTAssertGreaterThan(storm.drops.reduce(0) {$0+$1.volume},medium.drops.reduce(0) {$0+$1.volume}*2)
        for _ in 0..<1800 { storm.step(dt:1/30,size:SIMD2(1000,800),intensity:8.4) }
        XCTAssertLessThanOrEqual(storm.drops.count,3600)
        XCTAssertLessThanOrEqual(storm.trails.count,16000)
        storm.wipe(from:SIMD2(0,400),to:SIMD2(1000,400),radius:2000)
        XCTAssertTrue(storm.drops.isEmpty)
        XCTAssertTrue(storm.trails.isEmpty)
    }

}
