// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BarKeep",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector.git", exact: "0.10.5"),
    ],
    targets: [
        .executableTarget(
            name: "BarKeep",
            path: "Sources/BarKeep"
        ),
        .testTarget(
            name: "BarKeepTests",
            dependencies: ["BarKeep", .product(name: "ViewInspector", package: "ViewInspector")],
            path: "Tests/BarKeepTests"
        )
    ]
)
