// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BonjourAdvertiser",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "quic-video-bonjour", targets: ["BonjourAdvertiser"]),
    ],
    targets: [
        .executableTarget(name: "BonjourAdvertiser"),
    ]
)
