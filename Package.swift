// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BarKeep",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BarKeep",
            path: "Sources/BarKeep"
        ),
        .testTarget(
            name: "BarKeepTests",
            dependencies: ["BarKeep"],
            path: "Tests/BarKeepTests"
        )
    ]
)
