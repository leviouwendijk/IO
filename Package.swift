// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "IO",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "IO",
            targets: [
                "IO",
            ]
        ),
    ],
    targets: [
        .target(
            name: "IO"
        ),
    ]
)
