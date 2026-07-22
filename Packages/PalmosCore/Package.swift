// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PalmosCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PalmosCore", targets: ["PalmosCore"])
    ],
    targets: [
        .target(name: "PalmosCore"),
        .testTarget(
            name: "PalmosCoreTests",
            dependencies: ["PalmosCore"]
        )
    ]
)
