import Foundation
import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    enum ResolutionDecompositionLane:
        Hashable
    {
        case foundation
        case standardize_url
        case current_path_preparation
        case file_system_representation
        case realpath_alloc_raw
        case realpath_alloc_url
        case realpath_alloc_url_standardized
        case realpath_fixed_raw
        case realpath_fixed_url
        case direct_lazy_alloc_candidate
        case direct_lazy_fixed_candidate
        case current_c
    }

    struct ResolutionDecompositionSummary {
        let minimum: Double
        let median: Double
        let maximum: Double
    }

    static func runFileSystemResolutionDecompositionBenchmarks(
        heavy: Bool
    ) throws {
        let root = temporaryFileSystemRoot(
            prefix: "io-fs-resolution-decompose"
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

        let directory = root.appendingPathComponent(
            "directory",
            isDirectory: true
        )
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        try writeFixtureFile(
            directory.appendingPathComponent(
                "child.txt"
            ),
            contents: "child\n"
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
                    "directory-link"
                ).path,
            withDestinationPath: "directory"
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
                "directory-link",
                root.appendingPathComponent(
                    "directory-link",
                    isDirectory: true
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
        print("filesystem resolution decomposition")
        print("production_changed: false")
        print(
            "heavy_iterations_per_lane: "
                + "\(heavy ? 30_000 : 3_000)"
        )
        print("lane_order: rotating_counterbalanced")
        print("")

        for item in cases {
            let foundation = FileSystem.foundation.resolve(
                item.1
            )
            let allocCandidate =
                resolutionDirectAllocCandidate(
                    item.1
                )
            let fixedCandidate =
                resolutionDirectFixedCandidate(
                    item.1
                )

            try expectEqual(
                allocCandidate,
                foundation,
                "direct allocated realpath candidate differs for \(item.0)"
            )
            try expectEqual(
                fixedCandidate,
                foundation,
                "direct fixed-buffer realpath candidate differs for \(item.0)"
            )

            try runResolutionDecompositionCase(
                name: item.0,
                url: item.1,
                iterations:
                    heavy
                    ? 30_000
                    : 3_000
            )
        }
    }
}

extension TestIO {
    static func runResolutionDecompositionCase(
        name: String,
        url: URL,
        iterations: Int
    ) throws {
        let standardized = url.standardizedFileURL
        let lanes: [ResolutionDecompositionLane] = [
            .foundation,
            .standardize_url,
            .current_path_preparation,
            .file_system_representation,
            .realpath_alloc_raw,
            .realpath_alloc_url,
            .realpath_alloc_url_standardized,
            .realpath_fixed_raw,
            .realpath_fixed_url,
            .direct_lazy_alloc_candidate,
            .direct_lazy_fixed_candidate,
            .current_c,
        ]
        let sampleCount = 7
        let baseIterations = iterations / sampleCount
        let extraIterations = iterations % sampleCount

        var samples: [
            ResolutionDecompositionLane: [Double]
        ] = [:]
        var sink = 0

        for sampleIndex in 0..<sampleCount {
            let sampleIterations =
                baseIterations
                + (sampleIndex < extraIterations ? 1 : 0)
            let rotation =
                sampleIndex % lanes.count
            let order =
                Array(lanes[rotation...])
                + Array(lanes[..<rotation])

            for lane in order {
                let seconds =
                    resolutionDecompositionMeasure(
                        iterations: sampleIterations
                    ) {
                        switch lane {
                        case .foundation:
                            sink &+= FileSystem.foundation.resolve(
                                url
                            ).path.count

                        case .standardize_url:
                            sink &+= url.standardizedFileURL.path.count

                        case .current_path_preparation:
                            let outer = url.standardizedFileURL
                            if let path = NativePath(
                                fileSystemURL: outer
                            ) {
                                sink &+= path.fileSystemBytes.count
                            } else {
                                sink &+= outer.path.count
                            }

                        case .file_system_representation:
                            standardized
                                .withUnsafeFileSystemRepresentation {
                                    pointer in

                                    guard let pointer else {
                                        sink &+= standardized.path.count
                                        return
                                    }

                                    sink &+= Int(
                                        strlen(
                                            pointer
                                        )
                                    )
                                }

                        case .realpath_alloc_raw:
                            resolutionRealpathAllocatedRaw(
                                standardized,
                                sink: &sink
                            )

                        case .realpath_alloc_url:
                            sink &+=
                                resolutionAllocatedURL(
                                    standardized,
                                    standardizeOutput: false
                                ).path.count

                        case .realpath_alloc_url_standardized:
                            sink &+=
                                resolutionAllocatedURL(
                                    standardized,
                                    standardizeOutput: true
                                ).path.count

                        case .realpath_fixed_raw:
                            resolutionRealpathFixedRaw(
                                standardized,
                                sink: &sink
                            )

                        case .realpath_fixed_url:
                            sink &+=
                                resolutionFixedURL(
                                    standardized
                                ).path.count

                        case .direct_lazy_alloc_candidate:
                            sink &+=
                                resolutionDirectAllocCandidate(
                                    url
                                ).path.count

                        case .direct_lazy_fixed_candidate:
                            sink &+=
                                resolutionDirectFixedCandidate(
                                    url
                                ).path.count

                        case .current_c:
                            sink &+= FileSystem.c.resolve(
                                url
                            ).path.count
                        }
                    }

                samples[lane, default: []].append(
                    seconds
                        / Double(
                            sampleIterations
                        )
                )
            }
        }

        withExtendedLifetime(
            sink
        ) {}

        print(name)
        print(
            "  iterations_per_lane: \(iterations)"
        )

        for lane in lanes {
            let summary =
                resolutionDecompositionSummary(
                    samples[lane] ?? []
                )
            printResolutionDecompositionSummary(
                name: resolutionLaneName(
                    lane
                ),
                summary: summary
            )
        }

        let foundation =
            resolutionDecompositionSummary(
                samples[.foundation] ?? []
            )
        let alloc =
            resolutionDecompositionSummary(
                samples[.direct_lazy_alloc_candidate] ?? []
            )
        let fixed =
            resolutionDecompositionSummary(
                samples[.direct_lazy_fixed_candidate] ?? []
            )
        let current =
            resolutionDecompositionSummary(
                samples[.current_c] ?? []
            )

        print(
            "  direct_alloc_vs_foundation_x: "
                + resolutionDecompositionFormattedRatio(
                    foundation.median
                        / max(
                            alloc.median,
                            .leastNonzeroMagnitude
                        )
                )
        )
        print(
            "  direct_fixed_vs_foundation_x: "
                + resolutionDecompositionFormattedRatio(
                    foundation.median
                        / max(
                            fixed.median,
                            .leastNonzeroMagnitude
                        )
                )
        )
        print(
            "  direct_alloc_vs_current_c_x: "
                + resolutionDecompositionFormattedRatio(
                    current.median
                        / max(
                            alloc.median,
                            .leastNonzeroMagnitude
                        )
                )
        )
        print(
            "  direct_fixed_vs_current_c_x: "
                + resolutionDecompositionFormattedRatio(
                    current.median
                        / max(
                            fixed.median,
                            .leastNonzeroMagnitude
                        )
                )
        )
        print("")
    }

    static func resolutionDirectAllocCandidate(
        _ input: URL
    ) -> URL {
        input.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer,
                  let resolved = realpath(
                    pointer,
                    nil
                  )
            else {
                return input.standardizedFileURL
            }

            defer {
                free(
                    resolved
                )
            }

            return URL(
                fileURLWithFileSystemRepresentation: resolved,
                isDirectory: input.hasDirectoryPath,
                relativeTo: nil
            ).standardizedFileURL
        }
    }

    static func resolutionDirectFixedCandidate(
        _ input: URL
    ) -> URL {
        input.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                return input.standardizedFileURL
            }

            return withUnsafeTemporaryAllocation(
                of: CChar.self,
                capacity: Int(PATH_MAX)
            ) {
                output in

                guard let baseAddress = output.baseAddress,
                      realpath(
                        pointer,
                        baseAddress
                      ) != nil
                else {
                    return input.standardizedFileURL
                }

                return URL(
                    fileURLWithFileSystemRepresentation: baseAddress,
                    isDirectory: input.hasDirectoryPath,
                    relativeTo: nil
                ).standardizedFileURL
            }
        }
    }

    static func resolutionAllocatedURL(
        _ standardized: URL,
        standardizeOutput: Bool
    ) -> URL {
        standardized.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer,
                  let resolved = realpath(
                    pointer,
                    nil
                  )
            else {
                return standardized
            }

            defer {
                free(
                    resolved
                )
            }

            let result = URL(
                fileURLWithFileSystemRepresentation: resolved,
                isDirectory: standardized.hasDirectoryPath,
                relativeTo: nil
            )

            return standardizeOutput
                ? result.standardizedFileURL
                : result
        }
    }

    static func resolutionFixedURL(
        _ standardized: URL
    ) -> URL {
        standardized.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                return standardized
            }

            return withUnsafeTemporaryAllocation(
                of: CChar.self,
                capacity: Int(PATH_MAX)
            ) {
                output in

                guard let baseAddress = output.baseAddress,
                      realpath(
                        pointer,
                        baseAddress
                      ) != nil
                else {
                    return standardized
                }

                return URL(
                    fileURLWithFileSystemRepresentation: baseAddress,
                    isDirectory: standardized.hasDirectoryPath,
                    relativeTo: nil
                )
            }
        }
    }

    static func resolutionRealpathAllocatedRaw(
        _ standardized: URL,
        sink: inout Int
    ) {
        standardized.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer,
                  let resolved = realpath(
                    pointer,
                    nil
                  )
            else {
                sink &+= standardized.path.count
                return
            }

            sink &+= Int(
                strlen(
                    resolved
                )
            )
            free(
                resolved
            )
        }
    }

    static func resolutionRealpathFixedRaw(
        _ standardized: URL,
        sink: inout Int
    ) {
        standardized.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                sink &+= standardized.path.count
                return
            }

            withUnsafeTemporaryAllocation(
                of: CChar.self,
                capacity: Int(PATH_MAX)
            ) {
                output in

                guard let baseAddress = output.baseAddress,
                      realpath(
                        pointer,
                        baseAddress
                      ) != nil
                else {
                    sink &+= standardized.path.count
                    return
                }

                sink &+= Int(
                    strlen(
                        baseAddress
                    )
                )
            }
        }
    }

    static func resolutionDecompositionMeasure(
        iterations: Int,
        operation: () -> Void
    ) -> Double {
        let clock = ContinuousClock()
        let started = clock.now

        for _ in 0..<iterations {
            operation()
        }

        let duration = started.duration(
            to: clock.now
        )
        let components = duration.components

        return Double(
            components.seconds
        ) + Double(
            components.attoseconds
        ) / 1_000_000_000_000_000_000
    }

    static func resolutionDecompositionSummary(
        _ samples: [Double]
    ) -> ResolutionDecompositionSummary {
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

    static func printResolutionDecompositionSummary(
        name: String,
        summary: ResolutionDecompositionSummary
    ) {
        print(
            "  \(name)_seconds_per_operation_min: "
                + resolutionDecompositionFormattedSeconds(
                    summary.minimum
                )
        )
        print(
            "  \(name)_seconds_per_operation_median: "
                + resolutionDecompositionFormattedSeconds(
                    summary.median
                )
        )
        print(
            "  \(name)_seconds_per_operation_max: "
                + resolutionDecompositionFormattedSeconds(
                    summary.maximum
                )
        )
    }

    static func resolutionLaneName(
        _ lane: ResolutionDecompositionLane
    ) -> String {
        switch lane {
        case .foundation:
            "foundation"
        case .standardize_url:
            "standardize_url"
        case .current_path_preparation:
            "current_path_preparation"
        case .file_system_representation:
            "file_system_representation"
        case .realpath_alloc_raw:
            "realpath_alloc_raw"
        case .realpath_alloc_url:
            "realpath_alloc_url"
        case .realpath_alloc_url_standardized:
            "realpath_alloc_url_standardized"
        case .realpath_fixed_raw:
            "realpath_fixed_raw"
        case .realpath_fixed_url:
            "realpath_fixed_url"
        case .direct_lazy_alloc_candidate:
            "direct_lazy_alloc_candidate"
        case .direct_lazy_fixed_candidate:
            "direct_lazy_fixed_candidate"
        case .current_c:
            "current_c"
        }
    }

    static func resolutionDecompositionFormattedSeconds(
        _ value: Double
    ) -> String {
        String(
            format: "%.9f",
            value
        )
    }

    static func resolutionDecompositionFormattedRatio(
        _ value: Double
    ) -> String {
        String(
            format: "%.3f",
            value
        )
    }
}
