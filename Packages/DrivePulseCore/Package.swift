// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DrivePulseCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DrivePulseCore", targets: ["DrivePulseCore"])
    ],
    targets: [
        .target(name: "DrivePulseCore"),
        .testTarget(
            name: "DrivePulseCoreTests",
            dependencies: ["DrivePulseCore"]
        )
    ]
)
