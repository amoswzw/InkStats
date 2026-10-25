// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InkStats",
    platforms: [.macOS(.v14)],
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
            dependencies: ["CSystem", "HelperShared"]
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
