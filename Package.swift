// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "IO",
    products: [
        .library(
            name: "IO",
            targets: ["IO"]
        ),
    ],
    targets: [
        .target(
            name: "IO"
        ),
    ],
    swiftLanguageModes: [.v6]
)
