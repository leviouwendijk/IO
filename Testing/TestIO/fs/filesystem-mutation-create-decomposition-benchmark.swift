import Foundation
import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    struct MutationCreateDecompositionFixture {
        let target: URL
        let cPath: [CChar]
    }

    enum MutationCreateDecompositionLane:
        String,
        CaseIterable,
        Hashable
    {
        case file_manager
        case prebuilt_c_path_mkdir
        case url_single_borrow_mkdir
        case url_single_borrow_scan_mkdir
        case url_double_borrow_scan_mkdir
        case file_system_c
    }

    struct MutationCreateDecompositionSummary {
        let minimum: Double
        let median: Double
        let maximum: Double
    }

    static func runFileSystemMutationCreateDecompositionBenchmarks(
        heavy: Bool
    ) throws {
        let rounds =
            heavy
            ? 12_000
            : 1_200
        let sampleCount = 7
        let lanes =
            MutationCreateDecompositionLane.allCases

        print("")
        print("filesystem mutation create decomposition")
        print("case: create-empty-directory")
        print("heavy: \(heavy)")
        print("rounds_per_lane: \(rounds)")
        print("samples_per_lane: \(sampleCount)")
        print("lane_order: rotating_all_lanes")
        print("setup_and_cleanup_timed: false")
        print("")

        var samples:
            [MutationCreateDecompositionLane: [Double]]
            = [:]

        let baseRounds =
            rounds / sampleCount
        let extraRounds =
            rounds % sampleCount

        for sampleIndex in 0..<sampleCount {
            let sampleRounds =
                baseRounds
                + (
                    sampleIndex
                        < extraRounds
                    ? 1
                    : 0
                )
            let rotation =
                sampleIndex
                % lanes.count
            let order =
                Array(
                    lanes[
                        rotation...
                    ]
                )
                + Array(
                    lanes[
                        ..<rotation
                    ]
                )

            for lane in order {
                let seconds =
                    try measureMutationCreateDecomposition(
                        lane: lane,
                        rounds: sampleRounds,
                        sampleIndex:
                            sampleIndex
                    )

                samples[
                    lane,
                    default: []
                ].append(
                    seconds
                        / Double(
                            sampleRounds
                        )
                )
            }
        }

        let fileManagerSummary =
            mutationCreateDecompositionSummary(
                samples[
                    .file_manager
                ] ?? []
            )

        for lane in lanes {
            let summary =
                mutationCreateDecompositionSummary(
                    samples[
                        lane
                    ] ?? []
                )

            print(
                lane.rawValue
            )
            print(
                "  seconds_per_operation_min: "
                + mutationCreateDecompositionSeconds(
                    summary.minimum
                )
            )
            print(
                "  seconds_per_operation_median: "
                + mutationCreateDecompositionSeconds(
                    summary.median
                )
            )
            print(
                "  seconds_per_operation_max: "
                + mutationCreateDecompositionSeconds(
                    summary.maximum
                )
            )
            print(
                "  vs_file_manager_x: "
                + mutationCreateDecompositionRatio(
                    fileManagerSummary.median
                        / max(
                            summary.median,
                            .leastNonzeroMagnitude
                        )
                )
            )
            print("")
        }
    }
}

extension TestIO {
    static func measureMutationCreateDecomposition(
        lane:
            MutationCreateDecompositionLane,
        rounds: Int,
        sampleIndex: Int
    ) throws -> Double {
        let manager =
            FileManager.default
        let root =
            temporaryFileSystemRoot(
                prefix:
                    "io-fs-mutation-create-decompose-\(lane.rawValue)-\(sampleIndex)"
            )
        let clock =
            ContinuousClock()
        var wallSeconds =
            0.0

        try manager.createDirectory(
            at: root,
            withIntermediateDirectories:
                true
        )

        defer {
            try? manager.removeItem(
                at: root
            )
        }

        for round in 0..<rounds {
            let roundRoot =
                root.appendingPathComponent(
                    String(
                        format:
                            "round-%06d",
                        round
                    ),
                    isDirectory: true
                )

            try manager.createDirectory(
                at: roundRoot,
                withIntermediateDirectories:
                    false
            )

            let target =
                roundRoot.appendingPathComponent(
                    "created",
                    isDirectory: true
                )
            let cPath =
                try mutationCreateDecompositionCString(
                    target
                )
            let fixture =
                MutationCreateDecompositionFixture(
                    target: target,
                    cPath: cPath
                )

            let started =
                clock.now

            try mutationCreateDecompositionOperation(
                lane,
                fixture: fixture
            )

            wallSeconds +=
                mutationCreateDecompositionDurationSeconds(
                    started.duration(
                        to: clock.now
                    )
                )

            try manager.removeItem(
                at: roundRoot
            )
        }

        return wallSeconds
    }

    @inline(never)
    static func mutationCreateDecompositionOperation(
        _ lane:
            MutationCreateDecompositionLane,
        fixture:
            MutationCreateDecompositionFixture
    ) throws {
        switch lane {
        case .file_manager:
            try FileManager.default.createDirectory(
                at: fixture.target,
                withIntermediateDirectories:
                    false
            )

        case .prebuilt_c_path_mkdir:
            let result =
                fixture.cPath
                    .withUnsafeBufferPointer {
                        path in

                        guard let baseAddress =
                                path.baseAddress
                        else {
                            return Int32(-1)
                        }

                        return mutationCreateDecompositionMkdir(
                            baseAddress
                        )
                    }

            try mutationCreateDecompositionRequireSuccess(
                result,
                lane: lane
            )

        case .url_single_borrow_mkdir:
            var result =
                Int32(-1)

            fixture.target
                .withUnsafeFileSystemRepresentation {
                    pointer in

                    guard let pointer else {
                        return
                    }

                    result =
                        mutationCreateDecompositionMkdir(
                            pointer
                        )
                }

            try mutationCreateDecompositionRequireSuccess(
                result,
                lane: lane
            )

        case .url_single_borrow_scan_mkdir:
            var result =
                Int32(-1)

            fixture.target
                .withUnsafeFileSystemRepresentation {
                    pointer in

                    guard let pointer else {
                        return
                    }

                    precondition(
                        !mutationCreateDecompositionContainsDotComponent(
                            pointer
                        )
                    )

                    result =
                        mutationCreateDecompositionMkdir(
                            pointer
                        )
                }

            try mutationCreateDecompositionRequireSuccess(
                result,
                lane: lane
            )

        case .url_double_borrow_scan_mkdir:
            var hasDotComponent =
                true

            fixture.target
                .withUnsafeFileSystemRepresentation {
                    pointer in

                    guard let pointer else {
                        return
                    }

                    hasDotComponent =
                        mutationCreateDecompositionContainsDotComponent(
                            pointer
                        )
                }

            precondition(
                !hasDotComponent
            )

            var result =
                Int32(-1)

            fixture.target
                .withUnsafeFileSystemRepresentation {
                    pointer in

                    guard let pointer else {
                        return
                    }

                    result =
                        mutationCreateDecompositionMkdir(
                            pointer
                        )
                }

            try mutationCreateDecompositionRequireSuccess(
                result,
                lane: lane
            )

        case .file_system_c:
            try FileSystem.c.directory.create(
                fixture.target,
                intermediates: false
            )
        }
    }

    static func mutationCreateDecompositionCString(
        _ url: URL
    ) throws -> [CChar] {
        try url.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                throw TestFailure(
                    message:
                        "create decomposition could not obtain filesystem representation"
                )
            }

            let count =
                Int(
                    strlen(
                        pointer
                    )
                ) + 1

            return Array(
                UnsafeBufferPointer(
                    start: pointer,
                    count: count
                )
            )
        }
    }

    @inline(never)
    static func mutationCreateDecompositionContainsDotComponent(
        _ pointer:
            UnsafePointer<CChar>
    ) -> Bool {
        var index = 0

        while pointer[index] != 0 {
            let beginsComponent =
                index == 0
                || pointer[
                    index - 1
                ] == CChar(47)

            if beginsComponent,
               pointer[
                index
               ] == CChar(46)
            {
                let next =
                    pointer[
                        index + 1
                    ]

                if next == 0
                    || next == CChar(47)
                {
                    return true
                }

                if next == CChar(46) {
                    let after =
                        pointer[
                            index + 2
                        ]

                    if after == 0
                        || after == CChar(47)
                    {
                        return true
                    }
                }
            }

            index += 1
        }

        return false
    }

    static func mutationCreateDecompositionRequireSuccess(
        _ result: Int32,
        lane:
            MutationCreateDecompositionLane
    ) throws {
        guard result == 0 else {
            throw TestFailure(
                message:
                    "create decomposition lane \(lane.rawValue) failed with errno \(errno)"
            )
        }
    }

    static func mutationCreateDecompositionSummary(
        _ samples: [Double]
    ) -> MutationCreateDecompositionSummary {
        precondition(
            !samples.isEmpty
        )

        let sorted =
            samples.sorted()
        let middle =
            sorted.count / 2
        let median: Double

        if sorted.count.isMultiple(
            of: 2
        ) {
            median =
                (
                    sorted[
                        middle - 1
                    ]
                    + sorted[
                        middle
                    ]
                )
                / 2
        } else {
            median =
                sorted[
                    middle
                ]
        }

        return .init(
            minimum:
                sorted[0],
            median:
                median,
            maximum:
                sorted[
                    sorted.count - 1
                ]
        )
    }

    static func mutationCreateDecompositionDurationSeconds(
        _ duration:
            Duration
    ) -> Double {
        let components =
            duration.components

        return Double(
            components.seconds
        )
        + Double(
            components.attoseconds
        )
            / 1_000_000_000_000_000_000
    }

    static func mutationCreateDecompositionSeconds(
        _ value: Double
    ) -> String {
        String(
            format:
                "%.9f",
            value
        )
    }

    static func mutationCreateDecompositionRatio(
        _ value: Double
    ) -> String {
        String(
            format:
                "%.3f",
            value
        )
    }
}

@inline(__always)
private func mutationCreateDecompositionMkdir(
    _ pointer:
        UnsafePointer<CChar>
) -> Int32 {
    #if canImport(Darwin)
    Darwin.mkdir(
        pointer,
        mode_t(
            0o777
        )
    )
    #elseif canImport(Glibc)
    Glibc.mkdir(
        pointer,
        mode_t(
            0o777
        )
    )
    #endif
}
