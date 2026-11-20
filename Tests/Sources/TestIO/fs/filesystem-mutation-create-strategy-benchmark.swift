import Foundation
import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    enum MutationCreateEmptyStrategy:
        Int,
        CaseIterable,
        Hashable
    {
        case file_manager
        case prebuilt_mkdir
        case prebuilt_mkdirat_cwd
        case url_borrow_scan_mkdir
        case parent_fd_mkdirat
        case file_system_c
    }

    enum MutationCreateDeepStrategy:
        Int,
        CaseIterable,
        Hashable
    {
        case file_manager
        case file_system_c
        #if canImport(Darwin)
        case mkpath
        case mkpathat_cwd
        case parent_fd_mkpathat
        case open_parent_mkpathat
        #endif
    }

    struct MutationCreateStrategySample {
        let minimum: Double
        let median: Double
        let maximum: Double
    }

    static func runFileSystemMutationCreateStrategyBenchmarks(
        heavy: Bool
    ) throws {
        try runMutationEmptyCreateStrategies(
            heavy: heavy
        )
        try runMutationDeepCreateStrategies(
            heavy: heavy
        )
    }
}

extension TestIO {
    static func runMutationEmptyCreateStrategies(
        heavy: Bool
    ) throws {
        let rounds =
            heavy
            ? 10_000
            : 1_000
        let sampleCount = 7
        let lanes =
            MutationCreateEmptyStrategy.allCases

        print("")
        print("filesystem mutation create strategy")
        print("case: empty-directory")
        print("heavy: \(heavy)")
        print("rounds_per_lane: \(rounds)")
        print("samples_per_lane: \(sampleCount)")
        print("lane_order: per-round rotating")
        print("lane_path_lengths: equal")
        print("setup_and_cleanup_timed: false")
        print("")

        var samples:
            [MutationCreateEmptyStrategy: [Double]]
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
                        "io-fs-create-empty-paired-\(sampleIndex)"
                )
            let manager =
                FileManager.default
            let clock =
                ContinuousClock()
            var elapsed:
                [MutationCreateEmptyStrategy: Double]
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

                let parentFD =
                    try mutationCreateStrategyOpenDirectory(
                        roundRoot
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
                    let leaf =
                        String(
                            format:
                                "lane-%02d",
                            lane.rawValue
                        )
                    let target =
                        roundRoot.appendingPathComponent(
                            leaf,
                            isDirectory: true
                        )
                    let cPath =
                        try mutationCreateStrategyCString(
                            target
                        )

                    let started =
                        clock.now

                    try mutationEmptyCreateStrategyOperation(
                        lane,
                        target: target,
                        cPath: cPath,
                        parentFD: parentFD,
                        leaf: leaf
                    )

                    elapsed[
                        lane,
                        default: 0
                    ] +=
                        mutationCreateStrategyDurationSeconds(
                            started.duration(
                                to: clock.now
                            )
                        )

                    try manager.removeItem(
                        at: target
                    )
                }

                _ = mutationCreateStrategyClose(
                    parentFD
                )

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
            mutationCreateStrategySummary(
                samples[
                    .file_manager
                ] ?? []
            )

        for lane in lanes {
            mutationCreateStrategyPrint(
                name:
                    mutationEmptyCreateStrategyName(
                        lane
                    ),
                summary:
                    mutationCreateStrategySummary(
                        samples[
                            lane
                        ] ?? []
                    ),
                baseline:
                    baseline
            )
        }
    }

    static func runMutationDeepCreateStrategies(
        heavy: Bool
    ) throws {
        let rounds =
            heavy
            ? 2_800
            : 280
        let sampleCount = 7
        let lanes =
            MutationCreateDeepStrategy.allCases

        print("")
        print("filesystem mutation create strategy")
        print("case: deep-intermediates")
        print("heavy: \(heavy)")
        print("rounds_per_lane: \(rounds)")
        print("samples_per_lane: \(sampleCount)")
        print("lane_order: per-round rotating")
        print("lane_path_lengths: equal")
        print("setup_and_cleanup_timed: false")
        print("")

        var samples:
            [MutationCreateDeepStrategy: [Double]]
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
                        "io-fs-create-deep-paired-\(sampleIndex)"
                )
            let manager =
                FileManager.default
            let clock =
                ContinuousClock()
            var elapsed:
                [MutationCreateDeepStrategy: Double]
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
                        try mutationCreateStrategyCString(
                            target
                        )
                    let parentFD: Int32

                    #if canImport(Darwin)
                    if lane == .parent_fd_mkpathat {
                        parentFD =
                            try mutationCreateStrategyOpenDirectory(
                                laneRoot
                            )
                    } else {
                        parentFD = -1
                    }
                    #else
                    parentFD = -1
                    #endif

                    let started =
                        clock.now

                    try mutationDeepCreateStrategyOperation(
                        lane,
                        target: target,
                        parent: laneRoot,
                        cPath: cPath,
                        parentFD: parentFD
                    )

                    elapsed[
                        lane,
                        default: 0
                    ] +=
                        mutationCreateStrategyDurationSeconds(
                            started.duration(
                                to: clock.now
                            )
                        )

                    if parentFD >= 0 {
                        _ = mutationCreateStrategyClose(
                            parentFD
                        )
                    }

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
            mutationCreateStrategySummary(
                samples[
                    .file_manager
                ] ?? []
            )

        for lane in lanes {
            mutationCreateStrategyPrint(
                name:
                    mutationDeepCreateStrategyName(
                        lane
                    ),
                summary:
                    mutationCreateStrategySummary(
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
    static func mutationEmptyCreateStrategyOperation(
        _ lane:
            MutationCreateEmptyStrategy,
        target: URL,
        cPath: [CChar],
        parentFD: Int32,
        leaf: String
    ) throws {
        let result: Int32

        switch lane {
        case .file_manager:
            try FileManager.default.createDirectory(
                at: target,
                withIntermediateDirectories:
                    false
            )
            return

        case .prebuilt_mkdir:
            result =
                cPath.withUnsafeBufferPointer {
                    buffer in

                    guard let baseAddress =
                            buffer.baseAddress
                    else {
                        return Int32(-1)
                    }

                    return mutationCreateStrategyMkdir(
                        baseAddress
                    )
                }

        case .prebuilt_mkdirat_cwd:
            result =
                cPath.withUnsafeBufferPointer {
                    buffer in

                    guard let baseAddress =
                            buffer.baseAddress
                    else {
                        return Int32(-1)
                    }

                    return mutationCreateStrategyMkdirAt(
                        AT_FDCWD,
                        baseAddress
                    )
                }

        case .url_borrow_scan_mkdir:
            var operationResult =
                Int32(-1)

            target.withUnsafeFileSystemRepresentation {
                pointer in

                guard let pointer else {
                    return
                }

                precondition(
                    !mutationCreateStrategyContainsDotComponent(
                        pointer
                    )
                )

                operationResult =
                    mutationCreateStrategyMkdir(
                        pointer
                    )
            }

            result =
                operationResult

        case .parent_fd_mkdirat:
            result =
                leaf.withCString {
                    pointer in

                    mutationCreateStrategyMkdirAt(
                        parentFD,
                        pointer
                    )
                }

        case .file_system_c:
            try FileSystem.c.directory.create(
                target,
                intermediates: false
            )
            return
        }

        try mutationCreateStrategyRequireZero(
            result,
            name:
                mutationEmptyCreateStrategyName(
                    lane
                )
        )
    }

    @inline(never)
    static func mutationDeepCreateStrategyOperation(
        _ lane:
            MutationCreateDeepStrategy,
        target: URL,
        parent: URL,
        cPath: [CChar],
        parentFD: Int32
    ) throws {
        switch lane {
        case .file_manager:
            try FileManager.default.createDirectory(
                at: target,
                withIntermediateDirectories:
                    true
            )

        case .file_system_c:
            try FileSystem.c.directory.create(
                target,
                intermediates: true
            )

        #if canImport(Darwin)
        case .mkpath:
            let code =
                cPath.withUnsafeBufferPointer {
                    buffer in

                    guard let baseAddress =
                            buffer.baseAddress
                    else {
                        return Int32(EINVAL)
                    }

                    return mkpath_np(
                        baseAddress,
                        mode_t(
                            0o777
                        )
                    )
                }

            try mutationCreateStrategyRequireErrnoCode(
                code,
                name: "mkpath_np"
            )

        case .mkpathat_cwd:
            let code =
                cPath.withUnsafeBufferPointer {
                    buffer in

                    guard let baseAddress =
                            buffer.baseAddress
                    else {
                        return Int32(EINVAL)
                    }

                    return mkpathat_np(
                        AT_FDCWD,
                        baseAddress,
                        mode_t(
                            0o777
                        )
                    )
                }

            try mutationCreateStrategyRequireErrnoCode(
                code,
                name:
                    "mkpathat_np_at_fdcwd"
            )

        case .parent_fd_mkpathat:
            precondition(
                parentFD >= 0
            )

            let code =
                "a/b/c/d/e".withCString {
                    pointer in

                    mkpathat_np(
                        parentFD,
                        pointer,
                        mode_t(
                            0o777
                        )
                    )
                }

            try mutationCreateStrategyRequireErrnoCode(
                code,
                name:
                    "parent_fd_mkpathat_np"
            )

        case .open_parent_mkpathat:
            let descriptor =
                try mutationCreateStrategyOpenDirectory(
                    parent
                )

            defer {
                _ = mutationCreateStrategyClose(
                    descriptor
                )
            }

            let code =
                "a/b/c/d/e".withCString {
                    pointer in

                    mkpathat_np(
                        descriptor,
                        pointer,
                        mode_t(
                            0o777
                        )
                    )
                }

            try mutationCreateStrategyRequireErrnoCode(
                code,
                name:
                    "open_parent_mkpathat_np"
            )
        #endif
        }
    }

    static func mutationCreateStrategyCString(
        _ url: URL
    ) throws -> [CChar] {
        try url.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                throw TestFailure(
                    message:
                        "create strategy could not obtain filesystem representation"
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

    static func mutationCreateStrategyOpenDirectory(
        _ url: URL
    ) throws -> Int32 {
        let descriptor =
            url.withUnsafeFileSystemRepresentation {
                pointer in

                guard let pointer else {
                    return Int32(-1)
                }

                #if canImport(Darwin)
                return Darwin.open(
                    pointer,
                    O_RDONLY
                        | O_DIRECTORY
                        | O_CLOEXEC
                )
                #elseif canImport(Glibc)
                return Glibc.open(
                    pointer,
                    O_RDONLY
                        | O_DIRECTORY
                        | O_CLOEXEC
                )
                #endif
            }

        guard descriptor >= 0 else {
            throw TestFailure(
                message:
                    "create strategy could not open parent directory errno \(errno)"
            )
        }

        return descriptor
    }

    @inline(__always)
    static func mutationCreateStrategyClose(
        _ descriptor: Int32
    ) -> Int32 {
        #if canImport(Darwin)
        Darwin.close(
            descriptor
        )
        #elseif canImport(Glibc)
        Glibc.close(
            descriptor
        )
        #endif
    }

    @inline(never)
    static func mutationCreateStrategyContainsDotComponent(
        _ pointer:
            UnsafePointer<CChar>
    ) -> Bool {
        var index = 0

        while pointer[
            index
        ] != 0 {
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

    static func mutationCreateStrategySummary(
        _ values: [Double]
    ) -> MutationCreateStrategySample {
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

    static func mutationCreateStrategyPrint(
        name: String,
        summary:
            MutationCreateStrategySample,
        baseline:
            MutationCreateStrategySample
    ) {
        print(name)
        print(
            "  seconds_per_operation_min: "
            + mutationCreateStrategySeconds(
                summary.minimum
            )
        )
        print(
            "  seconds_per_operation_median: "
            + mutationCreateStrategySeconds(
                summary.median
            )
        )
        print(
            "  seconds_per_operation_max: "
            + mutationCreateStrategySeconds(
                summary.maximum
            )
        )
        print(
            "  vs_file_manager_x: "
            + mutationCreateStrategyRatio(
                baseline.median
                    / max(
                        summary.median,
                        .leastNonzeroMagnitude
                    )
            )
        )
        print("")
    }

    static func mutationEmptyCreateStrategyName(
        _ lane:
            MutationCreateEmptyStrategy
    ) -> String {
        switch lane {
        case .file_manager:
            "file_manager"
        case .prebuilt_mkdir:
            "prebuilt_mkdir"
        case .prebuilt_mkdirat_cwd:
            "prebuilt_mkdirat_at_fdcwd"
        case .url_borrow_scan_mkdir:
            "url_single_borrow_scan_mkdir"
        case .parent_fd_mkdirat:
            "parent_fd_mkdirat_lower_bound"
        case .file_system_c:
            "file_system_c"
        }
    }

    static func mutationDeepCreateStrategyName(
        _ lane:
            MutationCreateDeepStrategy
    ) -> String {
        switch lane {
        case .file_manager:
            "file_manager"
        case .file_system_c:
            "file_system_c"
        #if canImport(Darwin)
        case .mkpath:
            "mkpath_np"
        case .mkpathat_cwd:
            "mkpathat_np_at_fdcwd"
        case .parent_fd_mkpathat:
            "parent_fd_mkpathat_np_lower_bound"
        case .open_parent_mkpathat:
            "known_parent_open_mkpathat_np_end_to_end"
        #endif
        }
    }

    static func mutationCreateStrategyRequireZero(
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

    static func mutationCreateStrategyRequireErrnoCode(
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

    static func mutationCreateStrategyDurationSeconds(
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

    static func mutationCreateStrategySeconds(
        _ value: Double
    ) -> String {
        String(
            format:
                "%.9f",
            value
        )
    }

    static func mutationCreateStrategyRatio(
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
func mutationCreateStrategyMkdir(
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

@inline(__always)
func mutationCreateStrategyMkdirAt(
    _ descriptor: Int32,
    _ pointer:
        UnsafePointer<CChar>
) -> Int32 {
    mkdirat(
        descriptor,
        pointer,
        mode_t(
            0o777
        )
    )
}
