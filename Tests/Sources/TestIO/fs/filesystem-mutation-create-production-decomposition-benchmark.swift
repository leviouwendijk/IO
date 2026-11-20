import Foundation
import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    enum MutationCreateProductionEmptyLane:
        Int,
        CaseIterable,
        Hashable
    {
        case file_manager
        case prebuilt_mkdirat
        case url_borrow_mkdirat
        case url_borrow_scan_mkdirat
        case cached_directory_c
        case cached_file_system_c
        case static_file_system_c
    }

    enum MutationCreateProductionDeepLane:
        Int,
        CaseIterable,
        Hashable
    {
        case file_manager
        #if canImport(Darwin)
        case prebuilt_mkpathat
        case url_borrow_mkpathat
        case url_borrow_scan_mkpathat
        #endif
        case cached_directory_c
        case cached_file_system_c
        case static_file_system_c
    }

    struct MutationCreateProductionSample {
        let minimum: Double
        let median: Double
        let maximum: Double
    }

    static func runFileSystemMutationCreateProductionDecompositionBenchmarks(
        heavy: Bool
    ) throws {
        try runMutationCreateProductionEmptyDecomposition(
            heavy: heavy
        )
        try runMutationCreateProductionDeepDecomposition(
            heavy: heavy
        )
    }
}

extension TestIO {
    static func runMutationCreateProductionEmptyDecomposition(
        heavy: Bool
    ) throws {
        let rounds =
            heavy
            ? 10_000
            : 1_000
        let sampleCount = 7
        let lanes =
            MutationCreateProductionEmptyLane.allCases
        let manager =
            FileManager.default
        let cachedFileSystem =
            FileSystem.c
        let cachedDirectory =
            cachedFileSystem.directory

        print("")
        print("filesystem mutation create production decomposition")
        print("case: empty-directory")
        print("heavy: \(heavy)")
        print("rounds_per_lane: \(rounds)")
        print("samples_per_lane: \(sampleCount)")
        print("lane_order: per-round rotating")
        print("lane_path_lengths: equal")
        print("setup_and_cleanup_timed: false")
        print("")

        var samples:
            [MutationCreateProductionEmptyLane: [Double]]
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
            let root =
                temporaryFileSystemRoot(
                    prefix:
                        "io-fs-create-prod-empty-\(sampleIndex)"
                )
            let clock =
                ContinuousClock()
            var elapsed:
                [MutationCreateProductionEmptyLane: Double]
                = [:]

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

            for round in 0..<sampleRounds {
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

                let rotation =
                    (
                        sampleIndex
                        + round
                    )
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
                    let target =
                        roundRoot.appendingPathComponent(
                            String(
                                format:
                                    "lane-%02d",
                                lane.rawValue
                            ),
                            isDirectory: true
                        )
                    let cPath =
                        try mutationCreateProductionCString(
                            target
                        )

                    let started =
                        clock.now

                    try mutationCreateProductionEmptyOperation(
                        lane,
                        target: target,
                        cPath: cPath,
                        cachedFileSystem:
                            cachedFileSystem,
                        cachedDirectory:
                            cachedDirectory
                    )

                    elapsed[
                        lane,
                        default: 0
                    ] +=
                        mutationCreateProductionDurationSeconds(
                            started.duration(
                                to: clock.now
                            )
                        )

                    try manager.removeItem(
                        at: target
                    )
                }

                try manager.removeItem(
                    at: roundRoot
                )
            }

            for lane in lanes {
                samples[
                    lane,
                    default: []
                ].append(
                    (
                        elapsed[
                            lane
                        ] ?? 0
                    )
                    / Double(
                        sampleRounds
                    )
                )
            }
        }

        let baseline =
            mutationCreateProductionSummary(
                samples[
                    .file_manager
                ] ?? []
            )

        for lane in lanes {
            mutationCreateProductionPrint(
                name:
                    mutationCreateProductionEmptyName(
                        lane
                    ),
                summary:
                    mutationCreateProductionSummary(
                        samples[
                            lane
                        ] ?? []
                    ),
                baseline:
                    baseline
            )
        }
    }

    static func runMutationCreateProductionDeepDecomposition(
        heavy: Bool
    ) throws {
        let rounds =
            heavy
            ? 2_800
            : 280
        let sampleCount = 7
        let lanes =
            MutationCreateProductionDeepLane.allCases
        let manager =
            FileManager.default
        let cachedFileSystem =
            FileSystem.c
        let cachedDirectory =
            cachedFileSystem.directory

        print("")
        print("filesystem mutation create production decomposition")
        print("case: deep-intermediates")
        print("heavy: \(heavy)")
        print("rounds_per_lane: \(rounds)")
        print("samples_per_lane: \(sampleCount)")
        print("lane_order: per-round rotating")
        print("lane_path_lengths: equal")
        print("setup_and_cleanup_timed: false")
        print("")

        var samples:
            [MutationCreateProductionDeepLane: [Double]]
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
            let root =
                temporaryFileSystemRoot(
                    prefix:
                        "io-fs-create-prod-deep-\(sampleIndex)"
                )
            let clock =
                ContinuousClock()
            var elapsed:
                [MutationCreateProductionDeepLane: Double]
                = [:]

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

            for round in 0..<sampleRounds {
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

                let rotation =
                    (
                        sampleIndex
                        + round
                    )
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
                    let laneRoot =
                        roundRoot.appendingPathComponent(
                            String(
                                format:
                                    "lane-%02d",
                                lane.rawValue
                            ),
                            isDirectory: true
                        )

                    try manager.createDirectory(
                        at: laneRoot,
                        withIntermediateDirectories:
                            false
                    )

                    let target =
                        laneRoot
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
                    let cPath =
                        try mutationCreateProductionCString(
                            target
                        )

                    let started =
                        clock.now

                    try mutationCreateProductionDeepOperation(
                        lane,
                        target: target,
                        cPath: cPath,
                        cachedFileSystem:
                            cachedFileSystem,
                        cachedDirectory:
                            cachedDirectory
                    )

                    elapsed[
                        lane,
                        default: 0
                    ] +=
                        mutationCreateProductionDurationSeconds(
                            started.duration(
                                to: clock.now
                            )
                        )

                    try manager.removeItem(
                        at: laneRoot
                    )
                }

                try manager.removeItem(
                    at: roundRoot
                )
            }

            for lane in lanes {
                samples[
                    lane,
                    default: []
                ].append(
                    (
                        elapsed[
                            lane
                        ] ?? 0
                    )
                    / Double(
                        sampleRounds
                    )
                )
            }
        }

        let baseline =
            mutationCreateProductionSummary(
                samples[
                    .file_manager
                ] ?? []
            )

        for lane in lanes {
            mutationCreateProductionPrint(
                name:
                    mutationCreateProductionDeepName(
                        lane
                    ),
                summary:
                    mutationCreateProductionSummary(
                        samples[
                            lane
                        ] ?? []
                    ),
                baseline:
                    baseline
            )
        }
    }

    @inline(never)
    static func mutationCreateProductionEmptyOperation(
        _ lane:
            MutationCreateProductionEmptyLane,
        target: URL,
        cPath: [CChar],
        cachedFileSystem: FileSystem,
        cachedDirectory:
            FileSystem.Directory
    ) throws {
        switch lane {
        case .file_manager:
            try FileManager.default.createDirectory(
                at: target,
                withIntermediateDirectories:
                    false
            )

        case .prebuilt_mkdirat:
            let result =
                cPath.withUnsafeBufferPointer {
                    buffer in

                    guard let pointer =
                            buffer.baseAddress
                    else {
                        return Int32(-1)
                    }

                    return mutationCreateProductionMkdirAt(
                        pointer
                    )
                }

            try mutationCreateProductionRequireZero(
                result,
                name:
                    "prebuilt_mkdirat_at_fdcwd"
            )

        case .url_borrow_mkdirat:
            let result =
                target.withUnsafeFileSystemRepresentation {
                    pointer in

                    guard let pointer else {
                        return Int32(-1)
                    }

                    return mutationCreateProductionMkdirAt(
                        pointer
                    )
                }

            try mutationCreateProductionRequireZero(
                result,
                name:
                    "url_borrow_mkdirat_at_fdcwd"
            )

        case .url_borrow_scan_mkdirat:
            let result =
                target.withUnsafeFileSystemRepresentation {
                    pointer in

                    guard let pointer else {
                        return Int32(-1)
                    }

                    precondition(
                        !mutationCreateProductionContainsDotComponent(
                            pointer
                        )
                    )

                    return mutationCreateProductionMkdirAt(
                        pointer
                    )
                }

            try mutationCreateProductionRequireZero(
                result,
                name:
                    "url_borrow_scan_mkdirat_at_fdcwd"
            )

        case .cached_directory_c:
            try cachedDirectory.create(
                target,
                intermediates: false
            )

        case .cached_file_system_c:
            try cachedFileSystem.directory.create(
                target,
                intermediates: false
            )

        case .static_file_system_c:
            try FileSystem.c.directory.create(
                target,
                intermediates: false
            )
        }
    }

    @inline(never)
    static func mutationCreateProductionDeepOperation(
        _ lane:
            MutationCreateProductionDeepLane,
        target: URL,
        cPath: [CChar],
        cachedFileSystem: FileSystem,
        cachedDirectory:
            FileSystem.Directory
    ) throws {
        switch lane {
        case .file_manager:
            try FileManager.default.createDirectory(
                at: target,
                withIntermediateDirectories:
                    true
            )

        #if canImport(Darwin)
        case .prebuilt_mkpathat:
            let code =
                cPath.withUnsafeBufferPointer {
                    buffer in

                    guard let pointer =
                            buffer.baseAddress
                    else {
                        return Int32(EINVAL)
                    }

                    return mkpathat_np(
                        AT_FDCWD,
                        pointer,
                        mode_t(
                            0o777
                        )
                    )
                }

            try mutationCreateProductionRequireErrnoCode(
                code,
                name:
                    "prebuilt_mkpathat_np_at_fdcwd"
            )

        case .url_borrow_mkpathat:
            let code =
                target.withUnsafeFileSystemRepresentation {
                    pointer in

                    guard let pointer else {
                        return Int32(EINVAL)
                    }

                    return mkpathat_np(
                        AT_FDCWD,
                        pointer,
                        mode_t(
                            0o777
                        )
                    )
                }

            try mutationCreateProductionRequireErrnoCode(
                code,
                name:
                    "url_borrow_mkpathat_np_at_fdcwd"
            )

        case .url_borrow_scan_mkpathat:
            let code =
                target.withUnsafeFileSystemRepresentation {
                    pointer in

                    guard let pointer else {
                        return Int32(EINVAL)
                    }

                    precondition(
                        !mutationCreateProductionContainsDotComponent(
                            pointer
                        )
                    )

                    return mkpathat_np(
                        AT_FDCWD,
                        pointer,
                        mode_t(
                            0o777
                        )
                    )
                }

            try mutationCreateProductionRequireErrnoCode(
                code,
                name:
                    "url_borrow_scan_mkpathat_np_at_fdcwd"
            )
        #endif

        case .cached_directory_c:
            try cachedDirectory.create(
                target,
                intermediates: true
            )

        case .cached_file_system_c:
            try cachedFileSystem.directory.create(
                target,
                intermediates: true
            )

        case .static_file_system_c:
            try FileSystem.c.directory.create(
                target,
                intermediates: true
            )
        }
    }

    static func mutationCreateProductionCString(
        _ url: URL
    ) throws -> [CChar] {
        try url.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                throw TestFailure(
                    message:
                        "create production decomposition could not obtain filesystem representation"
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

    @inline(__always)
    static func mutationCreateProductionContainsDotComponent(
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

    @inline(__always)
    static func mutationCreateProductionMkdirAt(
        _ pointer:
            UnsafePointer<CChar>
    ) -> Int32 {
        mkdirat(
            AT_FDCWD,
            pointer,
            mode_t(
                0o777
            )
        )
    }

    static func mutationCreateProductionRequireZero(
        _ result: Int32,
        name: String
    ) throws {
        guard result == 0 else {
            throw TestFailure(
                message:
                    "\(name) failed errno \(errno)"
            )
        }
    }

    static func mutationCreateProductionRequireErrnoCode(
        _ code: Int32,
        name: String
    ) throws {
        guard code == 0
                || code == EEXIST
        else {
            throw TestFailure(
                message:
                    "\(name) failed code \(code)"
            )
        }
    }

    static func mutationCreateProductionSummary(
        _ values: [Double]
    ) -> MutationCreateProductionSample {
        precondition(
            !values.isEmpty
        )

        let sorted =
            values.sorted()
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

    static func mutationCreateProductionPrint(
        name: String,
        summary:
            MutationCreateProductionSample,
        baseline:
            MutationCreateProductionSample
    ) {
        print(name)
        print(
            "  seconds_per_operation_min: "
            + mutationCreateProductionSeconds(
                summary.minimum
            )
        )
        print(
            "  seconds_per_operation_median: "
            + mutationCreateProductionSeconds(
                summary.median
            )
        )
        print(
            "  seconds_per_operation_max: "
            + mutationCreateProductionSeconds(
                summary.maximum
            )
        )
        print(
            "  vs_file_manager_x: "
            + mutationCreateProductionRatio(
                baseline.median
                    / max(
                        summary.median,
                        .leastNonzeroMagnitude
                    )
            )
        )
        print("")
    }

    static func mutationCreateProductionEmptyName(
        _ lane:
            MutationCreateProductionEmptyLane
    ) -> String {
        switch lane {
        case .file_manager:
            "file_manager"
        case .prebuilt_mkdirat:
            "prebuilt_mkdirat_at_fdcwd"
        case .url_borrow_mkdirat:
            "url_borrow_mkdirat_at_fdcwd"
        case .url_borrow_scan_mkdirat:
            "url_borrow_scan_mkdirat_at_fdcwd"
        case .cached_directory_c:
            "cached_directory_c"
        case .cached_file_system_c:
            "cached_file_system_c"
        case .static_file_system_c:
            "static_file_system_c"
        }
    }

    static func mutationCreateProductionDeepName(
        _ lane:
            MutationCreateProductionDeepLane
    ) -> String {
        switch lane {
        case .file_manager:
            "file_manager"
        #if canImport(Darwin)
        case .prebuilt_mkpathat:
            "prebuilt_mkpathat_np_at_fdcwd"
        case .url_borrow_mkpathat:
            "url_borrow_mkpathat_np_at_fdcwd"
        case .url_borrow_scan_mkpathat:
            "url_borrow_scan_mkpathat_np_at_fdcwd"
        #endif
        case .cached_directory_c:
            "cached_directory_c"
        case .cached_file_system_c:
            "cached_file_system_c"
        case .static_file_system_c:
            "static_file_system_c"
        }
    }

    static func mutationCreateProductionDurationSeconds(
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

    static func mutationCreateProductionSeconds(
        _ value: Double
    ) -> String {
        String(
            format:
                "%.9f",
            value
        )
    }

    static func mutationCreateProductionRatio(
        _ value: Double
    ) -> String {
        String(
            format:
                "%.3f",
            value
        )
    }
}
