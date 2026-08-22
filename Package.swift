// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HeadsetCompanion",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "HeadsetCompanion",
            path: "Sources/HeadsetCompanion"
        ),
        .testTarget(
            name: "HeadsetCompanionTests",
            dependencies: ["HeadsetCompanion"],
            path: "Tests/HeadsetCompanionTests"
        ),
    ]
)
