// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Leporelo",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LeporeloCore", targets: ["LeporeloCore"]),
    ],
    targets: [
        .target(
            name: "LeporeloCore",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "LeporeloCoreTests",
            dependencies: ["LeporeloCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
