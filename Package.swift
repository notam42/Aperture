// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Aperture",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .macCatalyst(.v26),
    ],
    products: [
        .library(
            name: "Aperture",
            targets: ["Aperture"]
        ),
    ],
    targets: [
        .target(
            name: "Aperture",
            swiftSettings: [
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
    ]
)
