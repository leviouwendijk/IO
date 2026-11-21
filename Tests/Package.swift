// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "IOTests",
    platforms: [
        .macOS(.v13)
    ],
    products: [

        // test targets
        .executable(
            name: "tio",
            targets: [
                "tio",
            ]
        ),
        .executable(
            name: "tio_core",
            targets: [
                "tio_core",
            ]
        ),
        .executable(
            name: "tio_stream",
            targets: [
                "tio_stream",
            ]
        ),
        .executable(
            name: "tio_scan",
            targets: [
                "tio_scan",
            ]
        ),
        .executable(
            name: "tio_file",
            targets: [
                "tio_file",
            ]
        ),
        .executable(
            name: "tio_overhead",
            targets: [
                "tio_overhead",
            ]
        ),
        .executable(
            name: "tio_fs",
            targets: [
                "tio_fs",
            ]
        ),
        .executable(
            name: "tio_exec",
            targets: [
                "tio_exec",
            ]
        ),
        .executable(
            name: "tio_hazard",
            targets: [
                "tio_hazard",
            ]
        ),
        .executable(
            name: "tio_hazard_gate",
            targets: [
                "tio_hazard_gate",
            ]
        ),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/leviouwendijk/Errors.git", branch: "master"),
    ],
    targets: [

        // testing targets
        .target(
            name: "TestIO",
            dependencies: [
                .product(name: "IO", package: "IO"),
                .product(name: "Errors", package: "Errors"),
            ]
        ),
        .executableTarget(
            name: "tio",
            dependencies: [
                "TestIO",
            ]
        ),
        .executableTarget(
            name: "tio_core",
            dependencies: [
                "TestIO",
            ]
        ),
        .executableTarget(
            name: "tio_stream",
            dependencies: [
                "TestIO",
            ]
        ),
        .executableTarget(
            name: "tio_scan",
            dependencies: [
                "TestIO",
            ]
        ),
        .executableTarget(
            name: "tio_file",
            dependencies: [
                "TestIO",
            ]
        ),
        .executableTarget(
            name: "tio_overhead",
            dependencies: [
                "TestIO",
            ]
        ),
        .executableTarget(
            name: "tio_fs",
            dependencies: [
                "TestIO",
            ]
        ),
        .executableTarget(
            name: "tio_exec",
            dependencies: [
                "TestIO",
            ]
        ),
        .executableTarget(
            name: "tio_hazard",
            dependencies: [
                "TestIO",
            ]
        ),
        .executableTarget(
            name: "tio_hazard_gate",
            dependencies: [
                "TestIO",
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
