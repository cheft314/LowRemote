// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacRemoteServer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacRemoteServer", targets: ["MacRemoteServer"])
    ],
    targets: [
        .executableTarget(
            name: "MacRemoteServer",
            path: "Sources/MacRemoteServer",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Network")
            ]
        )
    ]
)
