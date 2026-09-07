// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "RainyScreen", platforms: [.macOS(.v14)],
    products: [.executable(name: "RainyScreen", targets: ["RainyScreen"])],
    targets: [
        .target(name: "RainCore"),
        .executableTarget(name: "RainyScreen", dependencies: ["RainCore"], resources: [.copy("Rain.metal")]),
        .testTarget(name: "RainCoreTests", dependencies: ["RainCore"])
    ], swiftLanguageModes: [.v5]
)
