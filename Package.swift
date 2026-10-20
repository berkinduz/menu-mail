// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MenuMail",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MenuMail", targets: ["MenuMail"])
    ],
    targets: [
        .executableTarget(name: "MenuMail"),
        .testTarget(name: "MenuMailTests", dependencies: ["MenuMail"])
    ]
)
