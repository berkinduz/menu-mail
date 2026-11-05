// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Envl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Envl", targets: ["Envl"])
    ],
    targets: [
        .executableTarget(name: "Envl"),
        .testTarget(name: "EnvlTests", dependencies: ["Envl"])
    ]
)
