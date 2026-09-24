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
        .package(
            url: "https://github.com/leviouwendijk/Atomos.git",
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
            ],
            swiftSettings: [
                .enableExperimentalFeature("LifetimeDependence"),
                .enableExperimentalFeature("Lifetimes"),
            ]
        ),

        // testing targets
        .target(
            name: "TestIO",
            dependencies: [
                "IO",
            ],
            path: "Testing/TestIO"
        ),
        .executableTarget(
            name: "tio",
            dependencies: [
                "TestIO",
            ],
            path: "Testing/tio"
        ),
        .executableTarget(
            name: "tio_core",
            dependencies: [
                "TestIO",
            ],
            path: "Testing/tio_core"
        ),
        .executableTarget(
            name: "tio_stream",
            dependencies: [
                "TestIO",
            ],
            path: "Testing/tio_stream"
        ),
        .executableTarget(
            name: "tio_scan",
            dependencies: [
                "TestIO",
            ],
            path: "Testing/tio_scan"
        ),
        .executableTarget(
            name: "tio_file",
            dependencies: [
                "TestIO",
            ],
            path: "Testing/tio_file"
        ),
        .executableTarget(
            name: "tio_overhead",
            dependencies: [
                "TestIO",
            ],
            path: "Testing/tio_overhead"
        ),
        .executableTarget(
            name: "tio_fs",
            dependencies: [
                "TestIO",
            ],
            path: "Testing/tio_fs"
        ),
        .executableTarget(
            name: "tio_exec",
            dependencies: [
                "TestIO",
            ],
            path: "Testing/tio_exec"
        ),
        .executableTarget(
            name: "tio_hazard",
            dependencies: [
                "TestIO",
            ],
            path: "Testing/tio_hazard"
        ),
        .executableTarget(
            name: "tio_hazard_gate",
            dependencies: [
                "TestIO",
            ],
            path: "Testing/tio_hazard_gate"
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
