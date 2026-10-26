// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Leporelo",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LeporeloCore", targets: ["LeporeloCore"]),
        .executable(name: "leporelo-cli", targets: ["leporelo-cli"]),
    ],
    targets: [
        .target(
            name: "LeporeloCore",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "leporelo-cli",
            dependencies: ["LeporeloCore"]
        ),
        .testTarget(
            name: "LeporeloCoreTests",
            dependencies: ["LeporeloCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
