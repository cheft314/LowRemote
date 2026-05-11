// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LowRemote",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "LowRemote", targets: ["LowRemote"]),
    ],
    targets: [
        .target(
            name: "LowRemote",
            path: "LowRemote",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
