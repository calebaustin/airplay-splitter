// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AirPlaySplitter",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "VirtualDisplayShim",
            path: "Sources/VirtualDisplayShim",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "AirPlaySplitter",
            dependencies: ["VirtualDisplayShim"],
            path: "Sources/AirPlaySplitter",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
            ]
        ),
    ]
)
