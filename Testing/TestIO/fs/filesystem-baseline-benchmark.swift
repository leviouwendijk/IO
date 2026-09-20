import Foundation
import IO

extension TestIO {
    struct FileSystemBaselineCounters: Equatable {
        var directoriesEnumerated = 0
        var entriesReturned = 0
        var metadataInspections = 0
        var emptinessProbes = 0

        mutating func merge(
            _ other: Self
        ) {
            directoriesEnumerated += other.directoriesEnumerated
            entriesReturned += other.entriesReturned
            metadataInspections += other.metadataInspections
            emptinessProbes += other.emptinessProbes
        }
    }

    struct FileSystemBenchmarkMeasurement {
        let wallSeconds: Double
        let counters: FileSystemBaselineCounters
    }

    static func runFileSystemBaselineBenchmarks(
        heavy: Bool
    ) throws {
        try withFileSystemBenchmarkFixture(
            heavy: heavy
        ) { fixture in
            print("")
            print("filesystem Foundation baseline")
            print("implementation: FileSystem.foundation")
            print("heavy: \(heavy)")
            print("")

            try runFileSystemBenchmarkCase(
                name: "flat-small",
                rounds: heavy ? 2_000 : 250
            ) { counters in
                let entries = try FileSystem.foundation.directory.entries(
                    fixture.flatSmall
                )

                counters.directoriesEnumerated += 1
                counters.entriesReturned += entries.count
            }

            try runFileSystemBenchmarkCase(
                name: "flat-wide-1k",
                rounds: heavy ? 400 : 40
            ) { counters in
                let entries = try FileSystem.foundation.directory.entries(
                    fixture.flatWide1K
                )

                counters.directoriesEnumerated += 1
                counters.entriesReturned += entries.count
            }

            if let flatWide10K = fixture.flatWide10K {
                try runFileSystemBenchmarkCase(
                    name: "flat-wide-10k",
                    rounds: 40
                ) { counters in
                    let entries = try FileSystem.foundation.directory.entries(
                        flatWide10K
                    )

                    counters.directoriesEnumerated += 1
                    counters.entriesReturned += entries.count
                }
            }

            try runFileSystemBenchmarkCase(
                name: "deep-narrow",
                rounds: heavy ? 80 : 12
            ) { counters in
                let entries = try FileSystem.foundation.directory.entries(
                    fixture.deepNarrow,
                    recursive: true
                )

                counters.directoriesEnumerated += 1
                    + entries.lazy.filter {
                        $0.kind == .directory
                    }.count
                counters.entriesReturned += entries.count
            }

            try runFileSystemBenchmarkCase(
                name: "mixed-tree",
                rounds: heavy ? 300 : 40
            ) { counters in
                let entries = try FileSystem.foundation.directory.entries(
                    fixture.mixedTree
                )

                counters.directoriesEnumerated += 1
                counters.entriesReturned += entries.count
            }

            try runFileSystemBenchmarkCase(
                name: "empty-probe",
                rounds: heavy ? 100_000 : 10_000
            ) { counters in
                _ = try DirectoryInspector(
                    fixture.emptyDirectory,
                    fileSystem: .foundation
                ).isEmpty()

                counters.emptinessProbes += 1
            }

            let nonEmptyProbeDirectory =
                fixture.flatWide10K
                ?? fixture.flatWide1K

            try runFileSystemBenchmarkCase(
                name: "nonempty-probe",
                rounds: heavy ? 100 : 500
            ) { counters in
                _ = try DirectoryInspector(
                    nonEmptyProbeDirectory,
                    fileSystem: .foundation
                ).isEmpty()

                counters.emptinessProbes += 1
            }

            let metadataEntries = try FileSystem.foundation.directory.entries(
                fixture.flatWide1K
            )

            try runFileSystemBenchmarkCase(
                name: "metadata-batch",
                rounds: heavy ? 100 : 10
            ) { counters in
                for entry in metadataEntries {
                    _ = try FileInspector(
                        entry.url,
                        fileSystem: .foundation
                    ).inspect()

                    counters.metadataInspections += 1
                }
            }

            try runFileSystemBenchmarkCase(
                name: "path-shaped-repeated-expansion",
                rounds: heavy ? 150 : 20
            ) { counters in
                try pathShapedExpansion(
                    from: fixture.mixedTree,
                    fileSystem: .foundation,
                    counters: &counters
                )
            }
        }
    }

    static func runFileSystemComparisonBenchmarks(
        heavy: Bool
    ) throws {
        try withFileSystemBenchmarkFixture(
            heavy: heavy
        ) { fixture in
            print("")
            print("filesystem implementation comparison")
            print("foundation: FileSystem.foundation")
            print("c: FileSystem.c")
            print("heavy: \(heavy)")
            print("")

            try runFileSystemComparisonCase(
                name: "flat-small",
                rounds: heavy ? 2_000 : 250
            ) { fileSystem, counters in
                let entries = try fileSystem.directory.entries(
                    fixture.flatSmall
                )

                counters.directoriesEnumerated += 1
                counters.entriesReturned += entries.count
            }

            try runFileSystemComparisonCase(
                name: "flat-wide-1k",
                rounds: heavy ? 400 : 40
            ) { fileSystem, counters in
                let entries = try fileSystem.directory.entries(
                    fixture.flatWide1K
                )

                counters.directoriesEnumerated += 1
                counters.entriesReturned += entries.count
            }

            if let flatWide10K = fixture.flatWide10K {
                try runFileSystemComparisonCase(
                    name: "flat-wide-10k",
                    rounds: 40
                ) { fileSystem, counters in
                    let entries = try fileSystem.directory.entries(
                        flatWide10K
                    )

                    counters.directoriesEnumerated += 1
                    counters.entriesReturned += entries.count
                }
            }

            try runFileSystemComparisonCase(
                name: "deep-narrow",
                rounds: heavy ? 80 : 12
            ) { fileSystem, counters in
                let entries = try fileSystem.directory.entries(
                    fixture.deepNarrow,
                    recursive: true
                )

                counters.directoriesEnumerated += 1
                    + entries.lazy.filter {
                        $0.kind == .directory
                    }.count
                counters.entriesReturned += entries.count
            }

            try runFileSystemComparisonCase(
                name: "mixed-tree",
                rounds: heavy ? 300 : 40
            ) { fileSystem, counters in
                let entries = try fileSystem.directory.entries(
                    fixture.mixedTree
                )

                counters.directoriesEnumerated += 1
                counters.entriesReturned += entries.count
            }

            try runFileSystemComparisonCase(
                name: "empty-probe",
                rounds: heavy ? 100_000 : 10_000
            ) { fileSystem, counters in
                _ = try DirectoryInspector(
                    fixture.emptyDirectory,
                    fileSystem: fileSystem
                ).isEmpty()

                counters.emptinessProbes += 1
            }

            let nonEmptyProbeDirectory =
                fixture.flatWide10K
                ?? fixture.flatWide1K

            try runFileSystemComparisonCase(
                name: "nonempty-probe",
                rounds: heavy ? 100 : 500
            ) { fileSystem, counters in
                _ = try DirectoryInspector(
                    nonEmptyProbeDirectory,
                    fileSystem: fileSystem
                ).isEmpty()

                counters.emptinessProbes += 1
            }

            let metadataEntries = try FileSystem.foundation.directory.entries(
                fixture.flatWide1K
            )

            try runFileSystemComparisonCase(
                name: "metadata-batch",
                rounds: heavy ? 100 : 10
            ) { fileSystem, counters in
                for entry in metadataEntries {
                    _ = try FileInspector(
                        entry.url,
                        fileSystem: fileSystem
                    ).inspect()

                    counters.metadataInspections += 1
                }
            }

            try runFileSystemComparisonCase(
                name: "path-shaped-repeated-expansion",
                rounds: heavy ? 150 : 20
            ) { fileSystem, counters in
                try pathShapedExpansion(
                    from: fixture.mixedTree,
                    fileSystem: fileSystem,
                    counters: &counters
                )
            }
        }
    }

    static func pathShapedExpansion(
        from root: URL,
        fileSystem: FileSystem,
        counters: inout FileSystemBaselineCounters
    ) throws {
        var pending = [
            root.standardizedFileURL
        ]
        var index = 0

        while index < pending.count {
            let directory = pending[index]
            index += 1

            let entries = try fileSystem.directory.entries(
                directory
            ).sorted {
                $0.url.path < $1.url.path
            }

            counters.directoriesEnumerated += 1
            counters.entriesReturned += entries.count

            for entry in entries where entry.kind == .directory {
                pending.append(
                    entry.url
                )
            }
        }
    }

    private static func runFileSystemBenchmarkCase(
        name: String,
        rounds: Int,
        operation: (inout FileSystemBaselineCounters) throws -> Void
    ) throws {
        let measurement = try measureFileSystemBenchmarkCase(
            rounds: rounds,
            operation: operation
        )

        print(name)
        print("  rounds: \(rounds)")
        print(
            "  wall_seconds: "
                + formattedSeconds(
                    measurement.wallSeconds
                )
        )
        printCounters(
            measurement.counters
        )
        print("")
    }

    private static func runFileSystemComparisonCase(
        name: String,
        rounds: Int,
        operation:
            (
                FileSystem,
                inout FileSystemBaselineCounters
            ) throws -> Void
    ) throws {
        let foundation = try measureFileSystemBenchmarkCase(
            rounds: rounds
        ) { counters in
            try operation(
                .foundation,
                &counters
            )
        }

        let c = try measureFileSystemBenchmarkCase(
            rounds: rounds
        ) { counters in
            try operation(
                .c,
                &counters
            )
        }

        guard foundation.counters == c.counters else {
            throw TestFailure(
                message:
                    "filesystem comparison workload diverged for \(name)"
            )
        }

        print(name)
        print("  rounds: \(rounds)")
        print(
            "  foundation_wall_seconds: "
                + formattedSeconds(
                    foundation.wallSeconds
                )
        )
        print(
            "  c_wall_seconds: "
                + formattedSeconds(
                    c.wallSeconds
                )
        )
        print(
            "  speedup_x: "
                + String(
                    format: "%.3f",
                    foundation.wallSeconds
                        / c.wallSeconds
                )
        )
        printCounters(
            foundation.counters
        )
        print("")
    }

    private static func measureFileSystemBenchmarkCase(
        rounds: Int,
        operation: (inout FileSystemBaselineCounters) throws -> Void
    ) throws -> FileSystemBenchmarkMeasurement {
        let clock = ContinuousClock()
        let started = clock.now
        var counters = FileSystemBaselineCounters()

        for _ in 0..<rounds {
            try operation(
                &counters
            )
        }

        let elapsed = started.duration(
            to: clock.now
        )

        return .init(
            wallSeconds: seconds(
                elapsed
            ),
            counters: counters
        )
    }

    private static func printCounters(
        _ counters: FileSystemBaselineCounters
    ) {
        print(
            "  directories_enumerated: "
                + "\(counters.directoriesEnumerated)"
        )
        print(
            "  entries_returned: "
                + "\(counters.entriesReturned)"
        )
        print(
            "  metadata_inspections: "
                + "\(counters.metadataInspections)"
        )
        print(
            "  emptiness_probes: "
                + "\(counters.emptinessProbes)"
        )
    }

    private static func formattedSeconds(
        _ value: Double
    ) -> String {
        String(
            format: "%.6f",
            value
        )
    }

    private static func seconds(
        _ duration: Duration
    ) -> Double {
        let components = duration.components

        return Double(
            components.seconds
        ) + Double(
            components.attoseconds
        ) / 1_000_000_000_000_000_000
    }
}
