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
    dependencies: [
        .package(
            url: "https://github.com/leviouwendijk/Atomos.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/leviouwendijk/Errors.git",
            branch: "master"
        ),
    ],
    targets: [
        .target(
            name: "IO",
            dependencies: [
                .product(
                    name: "Atomos",
                    package: "Atomos"
                ),
                .product(
                    name: "Errors",
                    package: "Errors"
                ),
            ],
            swiftSettings: [
                .enableExperimentalFeature("LifetimeDependence"),
                .enableExperimentalFeature("Lifetimes"),
            ]
        ),
    ]
)

for target in package.targets {
    switch target.type {
    case .regular, .executable, .test, .macro:
        var settings = target.swiftSettings ?? []

        settings.append(
            .treatAllWarnings(as: .error)
        )

        target.swiftSettings = settings

    case .plugin, .system, .binary:
        break

    @unknown default:
        break
    }
}
