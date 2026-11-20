import Foundation
import IO

extension TestIO {
    enum ResolutionBenchmarkLane:
        Hashable
    {
        case direct_foundation
        case file_system_foundation
        case c
    }

    struct ResolutionBenchmarkSummary {
        let minimum: Double
        let median: Double
        let maximum: Double
    }

    static func runFileSystemResolutionComparisonBenchmarks(
        heavy: Bool
    ) throws {
        let root = temporaryFileSystemRoot(
            prefix: "io-fs-resolution-bench"
        )
        let manager = FileManager.default

        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        defer {
            try? manager.removeItem(
                at: root
            )
        }

        let target = root.appendingPathComponent(
            "target.txt"
        )
        try writeFixtureFile(
            target,
            contents: "target\n"
        )

        try manager.createSymbolicLink(
            atPath:
                root.appendingPathComponent(
                    "relative-link"
                ).path,
            withDestinationPath: "target.txt"
        )

        try manager.createSymbolicLink(
            atPath:
                root.appendingPathComponent(
                    "chain-a"
                ).path,
            withDestinationPath: "chain-b"
        )
        try manager.createSymbolicLink(
            atPath:
                root.appendingPathComponent(
                    "chain-b"
                ).path,
            withDestinationPath: "relative-link"
        )

        try manager.createSymbolicLink(
            atPath:
                root.appendingPathComponent(
                    "broken-link"
                ).path,
            withDestinationPath: "missing-target"
        )

        try manager.createSymbolicLink(
            atPath:
                root.appendingPathComponent(
                    "loop-a"
                ).path,
            withDestinationPath: "loop-b"
        )
        try manager.createSymbolicLink(
            atPath:
                root.appendingPathComponent(
                    "loop-b"
                ).path,
            withDestinationPath: "loop-a"
        )

        let cases: [(String, URL)] = [
            (
                "regular-file",
                target
            ),
            (
                "relative-link",
                root.appendingPathComponent(
                    "relative-link"
                )
            ),
            (
                "symlink-chain",
                root.appendingPathComponent(
                    "chain-a"
                )
            ),
            (
                "missing-leaf",
                root.appendingPathComponent(
                    "missing-leaf"
                )
            ),
            (
                "broken-link",
                root.appendingPathComponent(
                    "broken-link"
                )
            ),
            (
                "symlink-loop",
                root.appendingPathComponent(
                    "loop-a"
                )
            ),
        ]

        print("")
        print("filesystem resolution comparison")
        print(
            "direct_foundation: "
                + "URL.resolvingSymlinksInPath().standardizedFileURL"
        )
        print(
            "file_system_foundation: "
                + "FileSystem.foundation.resolve"
        )
        print("c: FileSystem.c.resolve")
        print("heavy: \(heavy)")
        print("lane_order: rotating_counterbalanced")
        print("")

        for item in cases {
            try runResolutionComparisonCase(
                name: item.0,
                url: item.1,
                iterations:
                    heavy
                    ? 100_000
                    : 10_000
            )
        }
    }
}

extension TestIO {
    static func runResolutionComparisonCase(
        name: String,
        url: URL,
        iterations: Int
    ) throws {
        let sampleCount = 7
        let baseIterations = iterations / sampleCount
        let extraIterations = iterations % sampleCount

        let laneOrders: [[ResolutionBenchmarkLane]] = [
            [
                .direct_foundation,
                .file_system_foundation,
                .c,
            ],
            [
                .file_system_foundation,
                .c,
                .direct_foundation,
            ],
            [
                .c,
                .direct_foundation,
                .file_system_foundation,
            ],
        ]

        var samples: [ResolutionBenchmarkLane: [Double]] = [
            .direct_foundation: [],
            .file_system_foundation: [],
            .c: [],
        ]

        var sink = 0

        for sampleIndex in 0..<sampleCount {
            let sampleIterations =
                baseIterations
                + (sampleIndex < extraIterations ? 1 : 0)
            let order = laneOrders[
                sampleIndex % laneOrders.count
            ]

            for lane in order {
                let seconds = resolutionBenchmarkMeasure(
                    iterations: sampleIterations
                ) {
                    let resolved: URL

                    switch lane {
                    case .direct_foundation:
                        resolved = url
                            .resolvingSymlinksInPath()
                            .standardizedFileURL

                    case .file_system_foundation:
                        resolved = FileSystem.foundation.resolve(
                            url
                        )

                    case .c:
                        resolved = FileSystem.c.resolve(
                            url
                        )
                    }

                    sink &+= resolved.path.count
                }

                samples[lane, default: []].append(
                    seconds / Double(sampleIterations)
                )
            }
        }

        withExtendedLifetime(
            sink
        ) {}

        let directFoundation = resolutionBenchmarkSummary(
            samples[.direct_foundation] ?? []
        )
        let fileSystemFoundation = resolutionBenchmarkSummary(
            samples[.file_system_foundation] ?? []
        )
        let c = resolutionBenchmarkSummary(
            samples[.c] ?? []
        )

        print(name)
        print(
            "  iterations_per_lane: \(iterations)"
        )
        printResolutionBenchmarkSummary(
            name: "direct_foundation",
            summary: directFoundation
        )
        printResolutionBenchmarkSummary(
            name: "file_system_foundation",
            summary: fileSystemFoundation
        )
        printResolutionBenchmarkSummary(
            name: "c",
            summary: c
        )
        print(
            "  c_vs_direct_foundation_x: "
                + resolutionFormattedRatio(
                    directFoundation.median
                        / max(
                            c.median,
                            .leastNonzeroMagnitude
                        )
                )
        )
        print(
            "  c_vs_file_system_foundation_x: "
                + resolutionFormattedRatio(
                    fileSystemFoundation.median
                        / max(
                            c.median,
                            .leastNonzeroMagnitude
                        )
                )
        )
        print("")
    }

    static func resolutionBenchmarkMeasure(
        iterations: Int,
        operation: () -> Void
    ) -> Double {
        let clock = ContinuousClock()
        let started = clock.now

        for _ in 0..<iterations {
            operation()
        }

        return resolutionDurationSeconds(
            started.duration(
                to: clock.now
            )
        )
    }

    static func resolutionBenchmarkSummary(
        _ samples: [Double]
    ) -> ResolutionBenchmarkSummary {
        precondition(
            !samples.isEmpty
        )

        let sorted = samples.sorted()
        let middle = sorted.count / 2

        return .init(
            minimum: sorted[0],
            median: sorted[middle],
            maximum: sorted[sorted.count - 1]
        )
    }

    static func printResolutionBenchmarkSummary(
        name: String,
        summary: ResolutionBenchmarkSummary
    ) {
        print(
            "  \(name)_seconds_per_operation_min: "
                + resolutionFormattedOperationSeconds(
                    summary.minimum
                )
        )
        print(
            "  \(name)_seconds_per_operation_median: "
                + resolutionFormattedOperationSeconds(
                    summary.median
                )
        )
        print(
            "  \(name)_seconds_per_operation_max: "
                + resolutionFormattedOperationSeconds(
                    summary.maximum
                )
        )
    }

    static func resolutionDurationSeconds(
        _ duration: Duration
    ) -> Double {
        let components = duration.components

        return Double(
            components.seconds
        ) + Double(
            components.attoseconds
        ) / 1_000_000_000_000_000_000
    }

    static func resolutionFormattedOperationSeconds(
        _ value: Double
    ) -> String {
        String(
            format: "%.9f",
            value
        )
    }

    static func resolutionFormattedRatio(
        _ value: Double
    ) -> String {
        String(
            format: "%.3f",
            value
        )
    }
}
