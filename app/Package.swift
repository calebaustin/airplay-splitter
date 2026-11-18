// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AirPlaySplitter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AirPlaySplitter",
            path: "Sources/AirPlaySplitter",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
            ]
        ),
    ]
)
