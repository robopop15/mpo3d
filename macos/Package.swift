// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MPO3DMac",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "MPO3DMac",
            targets: ["MPO3DMac"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "MPO3DMac",
            path: "Sources/MPO3DMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ]
)
