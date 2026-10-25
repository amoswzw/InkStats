// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InkStats",
    platforms: [.macOS(.v14)],
    dependencies: [
        // One argument per line: Dependabot reads the version requirement up to the line's end.
        .package(
            url: "https://github.com/amoswzw/InkKit.git",
            from: "0.1.0"
        ),
    ],
    targets: [
        .target(
            name: "CSystem",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("IOReport"),
            ]
        ),
        .target(name: "HelperShared"),
        .executableTarget(
            name: "InkStats",
            dependencies: ["CSystem", "HelperShared", .product(name: "InkKit", package: "InkKit")]
        ),
        .executableTarget(
            name: "InkStatsHelper",
            dependencies: ["CSystem", "HelperShared"]
        ),
        .testTarget(
            name: "InkStatsTests",
            dependencies: ["InkStats"]
        ),
    ]
)
