import Foundation
import IO

extension TestIO {
    private struct MutationBenchmarkFixture {
        let root: URL
        let source: URL?
        let destination: URL?
        let replacement: URL?
        let target: URL?
    }

    private struct MutationBenchmarkMeasurement {
        let wallSeconds: Double
        let operations: Int
    }

    private enum MutationBenchmarkLane:
        String,
        Hashable
    {
        case file_manager
        case foundation
        case c
    }

    private struct MutationBenchmarkSummary {
        let minimum: Double
        let median: Double
        let maximum: Double
    }

    static func runFileSystemMutationComparisonBenchmarks(
        heavy: Bool
    ) throws {
        print("")
        print("filesystem mutation comparison")
        print("file_manager: FileManager.default")
        print("foundation: FileSystem.foundation")
        print("c: FileSystem.c")
        print("heavy: \(heavy)")
        print("setup_and_cleanup_timed: false")
        print("")

        try runMutationComparisonCase(
            name: "create-empty-directory",
            rounds: heavy ? 10_000 : 1_000,
            makeFixture: { root in
                .init(
                    root: root,
                    source: nil,
                    destination: nil,
                    replacement: nil,
                    target: root.appendingPathComponent(
                        "created",
                        isDirectory: true
                    )
                )
            },
            fileManagerOperation: { fixture in
                try FileManager.default.createDirectory(
                    at: fixture.target!,
                    withIntermediateDirectories: false
                )
            },
            fileSystemOperation: { fileSystem, fixture in
                try fileSystem.directory.create(
                    fixture.target!,
                    intermediates: false
                )
            }
        )

        try runMutationComparisonCase(
            name: "create-deep-intermediates",
            rounds: heavy ? 2_000 : 200,
            makeFixture: { root in
                .init(
                    root: root,
                    source: nil,
                    destination: nil,
                    replacement: nil,
                    target: root
                        .appendingPathComponent(
                            "a",
                            isDirectory: true
                        )
                        .appendingPathComponent(
                            "b",
                            isDirectory: true
                        )
                        .appendingPathComponent(
                            "c",
                            isDirectory: true
                        )
                        .appendingPathComponent(
                            "d",
                            isDirectory: true
                        )
                        .appendingPathComponent(
                            "e",
                            isDirectory: true
                        )
                )
            },
            fileManagerOperation: { fixture in
                try FileManager.default.createDirectory(
                    at: fixture.target!,
                    withIntermediateDirectories: true
                )
            },
            fileSystemOperation: { fileSystem, fixture in
                try fileSystem.directory.create(
                    fixture.target!,
                    intermediates: true
                )
            }
        )

        try runMutationComparisonCase(
            name: "remove-4k-file",
            rounds: heavy ? 10_000 : 1_000,
            makeFixture: { root in
                let target = root.appendingPathComponent(
                    "remove.bin"
                )
                try mutationBenchmarkWrite(
                    target,
                    byteCount: 4 * 1024
                )
                return .init(
                    root: root,
                    source: nil,
                    destination: nil,
                    replacement: nil,
                    target: target
                )
            },
            fileManagerOperation: { fixture in
                try FileManager.default.removeItem(
                    at: fixture.target!
                )
            },
            fileSystemOperation: { fileSystem, fixture in
                try fileSystem.remove(
                    fixture.target!
                )
            }
        )

        try runMutationComparisonCase(
            name: "remove-mixed-tree",
            rounds: heavy ? 200 : 20,
            makeFixture: { root in
                let target = root.appendingPathComponent(
                    "tree",
                    isDirectory: true
                )
                try mutationBenchmarkTree(
                    target,
                    branches: heavy ? 16 : 8,
                    filesPerBranch: heavy ? 16 : 8
                )
                return .init(
                    root: root,
                    source: nil,
                    destination: nil,
                    replacement: nil,
                    target: target
                )
            },
            fileManagerOperation: { fixture in
                try FileManager.default.removeItem(
                    at: fixture.target!
                )
            },
            fileSystemOperation: { fileSystem, fixture in
                try fileSystem.remove(
                    fixture.target!
                )
            }
        )

        try runMutationComparisonCase(
            name: "move-4k-file",
            rounds: heavy ? 10_000 : 1_000,
            makeFixture: { root in
                let source = root.appendingPathComponent(
                    "source.bin"
                )
                let destination = root.appendingPathComponent(
                    "destination.bin"
                )
                try mutationBenchmarkWrite(
                    source,
                    byteCount: 4 * 1024
                )
                return .init(
                    root: root,
                    source: source,
                    destination: destination,
                    replacement: nil,
                    target: nil
                )
            },
            fileManagerOperation: { fixture in
                try FileManager.default.moveItem(
                    at: fixture.source!,
                    to: fixture.destination!
                )
            },
            fileSystemOperation: { fileSystem, fixture in
                try fileSystem.move(
                    fixture.source!,
                    to: fixture.destination!
                )
            }
        )

        try runMutationComparisonCase(
            name: "replace-4k-file",
            rounds: heavy ? 5_000 : 500,
            makeFixture: { root in
                let target = root.appendingPathComponent(
                    "original.bin"
                )
                let replacement = root.appendingPathComponent(
                    "replacement.bin"
                )
                try mutationBenchmarkWrite(
                    target,
                    byteCount: 4 * 1024
                )
                try mutationBenchmarkWrite(
                    replacement,
                    byteCount: 4 * 1024 + 17
                )
                return .init(
                    root: root,
                    source: nil,
                    destination: nil,
                    replacement: replacement,
                    target: target
                )
            },
            fileManagerOperation: { fixture in
                _ = try FileManager.default.replaceItemAt(
                    fixture.target!,
                    withItemAt: fixture.replacement!
                )
            },
            fileSystemOperation: { fileSystem, fixture in
                try fileSystem.replace(
                    fixture.target!,
                    with: fixture.replacement!
                )
            }
        )

        try runMutationCopyCase(
            name: "copy-4k-file",
            rounds: heavy ? 5_000 : 500,
            byteCount: 4 * 1024
        )

        try runMutationCopyCase(
            name: "copy-1m-file",
            rounds: heavy ? 250 : 30,
            byteCount: 1024 * 1024
        )

        if heavy {
            try runMutationCopyCase(
                name: "copy-16m-file",
                rounds: 20,
                byteCount: 16 * 1024 * 1024
            )
        }

        try runMutationComparisonCase(
            name: "copy-mixed-tree",
            rounds: heavy ? 100 : 10,
            makeFixture: { root in
                let source = root.appendingPathComponent(
                    "source",
                    isDirectory: true
                )
                let destination = root.appendingPathComponent(
                    "destination",
                    isDirectory: true
                )
                try mutationBenchmarkTree(
                    source,
                    branches: heavy ? 16 : 8,
                    filesPerBranch: heavy ? 16 : 8
                )
                return .init(
                    root: root,
                    source: source,
                    destination: destination,
                    replacement: nil,
                    target: nil
                )
            },
            fileManagerOperation: { fixture in
                try FileManager.default.copyItem(
                    at: fixture.source!,
                    to: fixture.destination!
                )
            },
            fileSystemOperation: { fileSystem, fixture in
                try fileSystem.copy(
                    fixture.source!,
                    to: fixture.destination!
                )
            }
        )
    }
}

private extension TestIO {
    static func runMutationCopyCase(
        name: String,
        rounds: Int,
        byteCount: Int
    ) throws {
        try runMutationComparisonCase(
            name: name,
            rounds: rounds,
            makeFixture: { root in
                let source = root.appendingPathComponent(
                    "source.bin"
                )
                let destination = root.appendingPathComponent(
                    "destination.bin"
                )
                try mutationBenchmarkWrite(
                    source,
                    byteCount: byteCount
                )
                return .init(
                    root: root,
                    source: source,
                    destination: destination,
                    replacement: nil,
                    target: nil
                )
            },
            fileManagerOperation: { fixture in
                try FileManager.default.copyItem(
                    at: fixture.source!,
                    to: fixture.destination!
                )
            },
            fileSystemOperation: { fileSystem, fixture in
                try fileSystem.copy(
                    fixture.source!,
                    to: fixture.destination!
                )
            }
        )
    }

    private static func runMutationComparisonCase(
        name: String,
        rounds: Int,
        makeFixture:
            (URL) throws -> MutationBenchmarkFixture,
        fileManagerOperation:
            (MutationBenchmarkFixture) throws -> Void,
        fileSystemOperation:
            (FileSystem, MutationBenchmarkFixture) throws -> Void
    ) throws {
        let sampleCount = min(
            7,
            max(
                1,
                rounds
            )
        )
        let baseRounds = rounds / sampleCount
        let extraRounds = rounds % sampleCount
        let laneOrders: [[MutationBenchmarkLane]] = [
            [
                .file_manager,
                .foundation,
                .c,
            ],
            [
                .foundation,
                .c,
                .file_manager,
            ],
            [
                .c,
                .file_manager,
                .foundation,
            ],
        ]

        var samples: [MutationBenchmarkLane: [Double]] = [
            .file_manager: [],
            .foundation: [],
            .c: [],
        ]

        for sampleIndex in 0..<sampleCount {
            let sampleRounds =
                baseRounds
                + (sampleIndex < extraRounds ? 1 : 0)
            let order = laneOrders[
                sampleIndex % laneOrders.count
            ]

            for lane in order {
                let measurement: MutationBenchmarkMeasurement

                switch lane {
                case .file_manager:
                    measurement = try measureMutationBenchmark(
                        name:
                            "\(name)-file-manager-sample-\(sampleIndex)",
                        rounds: sampleRounds,
                        makeFixture: makeFixture,
                        operation: fileManagerOperation
                    )

                case .foundation:
                    measurement = try measureMutationBenchmark(
                        name:
                            "\(name)-foundation-sample-\(sampleIndex)",
                        rounds: sampleRounds,
                        makeFixture: makeFixture
                    ) { fixture in
                        try fileSystemOperation(
                            .foundation,
                            fixture
                        )
                    }

                case .c:
                    measurement = try measureMutationBenchmark(
                        name:
                            "\(name)-c-sample-\(sampleIndex)",
                        rounds: sampleRounds,
                        makeFixture: makeFixture
                    ) { fixture in
                        try fileSystemOperation(
                            .c,
                            fixture
                        )
                    }
                }

                samples[lane, default: []].append(
                    measurement.wallSeconds
                        / Double(measurement.operations)
                )
            }
        }

        let fileManager = mutationBenchmarkSummary(
            samples[.file_manager] ?? []
        )
        let foundation = mutationBenchmarkSummary(
            samples[.foundation] ?? []
        )
        let c = mutationBenchmarkSummary(
            samples[.c] ?? []
        )

        print(name)
        print("  rounds_per_lane: \(rounds)")
        print("  samples_per_lane: \(sampleCount)")
        print("  lane_order: rotating_counterbalanced")
        printMutationBenchmarkSummary(
            name: "file_manager",
            summary: fileManager
        )
        printMutationBenchmarkSummary(
            name: "foundation",
            summary: foundation
        )
        printMutationBenchmarkSummary(
            name: "c",
            summary: c
        )
        print(
            "  foundation_vs_file_manager_x: "
                + mutationFormattedRatio(
                    fileManager.median
                        / max(
                            foundation.median,
                            .leastNonzeroMagnitude
                        )
                )
        )
        print(
            "  c_vs_foundation_x: "
                + mutationFormattedRatio(
                    foundation.median
                        / max(
                            c.median,
                            .leastNonzeroMagnitude
                        )
                )
        )
        print(
            "  c_vs_file_manager_x: "
                + mutationFormattedRatio(
                    fileManager.median
                        / max(
                            c.median,
                            .leastNonzeroMagnitude
                        )
                )
        )
        print("")
    }

    private static func mutationBenchmarkSummary(
        _ samples: [Double]
    ) -> MutationBenchmarkSummary {
        precondition(
            !samples.isEmpty
        )

        let sorted = samples.sorted()
        let middle = sorted.count / 2
        let median: Double

        if sorted.count.isMultiple(
            of: 2
        ) {
            median =
                (sorted[middle - 1] + sorted[middle])
                / 2
        } else {
            median = sorted[middle]
        }

        return .init(
            minimum: sorted[0],
            median: median,
            maximum: sorted[sorted.count - 1]
        )
    }

    private static func printMutationBenchmarkSummary(
        name: String,
        summary: MutationBenchmarkSummary
    ) {
        print(
            "  \(name)_seconds_per_operation_min: "
                + mutationFormattedOperationSeconds(
                    summary.minimum
                )
        )
        print(
            "  \(name)_seconds_per_operation_median: "
                + mutationFormattedOperationSeconds(
                    summary.median
                )
        )
        print(
            "  \(name)_seconds_per_operation_max: "
                + mutationFormattedOperationSeconds(
                    summary.maximum
                )
        )
    }

    private static func measureMutationBenchmark(
        name: String,
        rounds: Int,
        makeFixture:
            (URL) throws -> MutationBenchmarkFixture,
        operation:
            (MutationBenchmarkFixture) throws -> Void
    ) throws -> MutationBenchmarkMeasurement {
        let root = temporaryFileSystemRoot(
            prefix: "io-fs-mutation-bench-\(name)"
        )
        let manager = FileManager.default
        let clock = ContinuousClock()
        var wallSeconds = 0.0

        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        defer {
            try? manager.removeItem(
                at: root
            )
        }

        for round in 0..<rounds {
            let roundRoot = root.appendingPathComponent(
                String(
                    format: "round-%06d",
                    round
                ),
                isDirectory: true
            )

            try manager.createDirectory(
                at: roundRoot,
                withIntermediateDirectories: false
            )

            let fixture = try makeFixture(
                roundRoot
            )

            let started = clock.now
            try operation(
                fixture
            )
            wallSeconds += mutationDurationSeconds(
                started.duration(
                    to: clock.now
                )
            )

            try manager.removeItem(
                at: roundRoot
            )
        }

        return .init(
            wallSeconds: wallSeconds,
            operations: rounds
        )
    }

    static func mutationBenchmarkWrite(
        _ url: URL,
        byteCount: Int
    ) throws {
        try Data(
            repeating: 0x5a,
            count: byteCount
        ).write(
            to: url
        )
    }

    static func mutationBenchmarkTree(
        _ root: URL,
        branches: Int,
        filesPerBranch: Int
    ) throws {
        let manager = FileManager.default

        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        for branch in 0..<branches {
            let branchURL = root.appendingPathComponent(
                "branch-\(branch)",
                isDirectory: true
            )

            try manager.createDirectory(
                at: branchURL,
                withIntermediateDirectories: false
            )

            for fileIndex in 0..<filesPerBranch {
                try mutationBenchmarkWrite(
                    branchURL.appendingPathComponent(
                        "file-\(fileIndex).bin"
                    ),
                    byteCount:
                        512
                        + ((branch + fileIndex) % 8) * 127
                )
            }

            let leaf = branchURL.appendingPathComponent(
                "leaf",
                isDirectory: true
            )

            try manager.createDirectory(
                at: leaf,
                withIntermediateDirectories: false
            )

            try mutationBenchmarkWrite(
                leaf.appendingPathComponent(
                    "payload.bin"
                ),
                byteCount: 1024
            )
        }
    }

    static func mutationDurationSeconds(
        _ duration: Duration
    ) -> Double {
        let components = duration.components

        return Double(
            components.seconds
        ) + Double(
            components.attoseconds
        ) / 1_000_000_000_000_000_000
    }

    static func mutationFormattedSeconds(
        _ value: Double
    ) -> String {
        String(
            format: "%.6f",
            value
        )
    }

    static func mutationFormattedOperationSeconds(
        _ value: Double
    ) -> String {
        String(
            format: "%.9f",
            value
        )
    }

    static func mutationFormattedRatio(
        _ value: Double
    ) -> String {
        String(
            format: "%.3f",
            value
        )
    }
}
