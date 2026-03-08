// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Meridian",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        // No external Swift packages required — we use:
        //   - Virtualization.framework (Apple system framework)
        //   - AuthenticationServices (ASWebAuthenticationSession for Steam OpenID)
        //   - Steam Web API via URLSession (no SDK needed)
        //   - GitHub Releases API via URLSession
        //
        // If you later want a typed Steam Web API client, add:
        // .package(url: "https://github.com/sebj/Steam", from: "0.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "Meridian",
            path: "Meridian",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
