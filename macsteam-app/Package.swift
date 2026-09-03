// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacsteamApp",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
    targets: [
        .executableTarget(
            name: "MacsteamApp",
            dependencies: ["Sparkle"],
            path: "Sources/MacsteamApp"
        ),
        .testTarget(
            name: "MacsteamAppTests",
            dependencies: ["MacsteamApp"],
            path: "Tests/MacsteamAppTests"
        )
    ]
)
