// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Meridian",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Meridian",
            path: "Meridian",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MeridianTests",
            dependencies: [],
            path: "Tests/MeridianTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
    ]
)
