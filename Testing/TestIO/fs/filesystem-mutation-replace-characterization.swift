import Foundation
import IO

#if canImport(Darwin)
import Darwin
#endif

extension TestIO {
    enum MutationReplaceCandidate:
        Int,
        CaseIterable,
        Hashable
    {
        case file_manager
        #if canImport(Darwin)
        case renameat_overwrite
        case rename_swap_unlink
        case rename_swap_metadata_unlink
        #endif
    }

    struct MutationReplaceObservation {
        let exists: Bool
        let mode: UInt32?
        let inode: UInt64?
        let size: Int64?
        let modificationSeconds: Int64?
        let bytes: [UInt8]?
    }

    struct MutationReplaceBenchmarkSummary {
        let minimum: Double
        let median: Double
        let maximum: Double
    }

    static func runFileSystemMutationReplaceCharacterization(
        heavy: Bool
    ) throws {
        #if canImport(Darwin)
        try characterizeMutationReplaceCandidates()
        try runMutationReplaceCandidateBenchmarks(
            heavy: heavy
        )
        #else
        print(
            "filesystem mutation replace characterization is Darwin-only"
        )
        #endif
    }
}

#if canImport(Darwin)
extension TestIO {
    static func characterizeMutationReplaceCandidates() throws {
        print("")
        print("filesystem mutation replace characterization")
        print("oracle: FileManager.default.replaceItemAt")
        print("candidate_semantics: regular-file path/content/permissions/mtime/inode")
        print("")

        for candidate in MutationReplaceCandidate.allCases {
            let root =
                temporaryFileSystemRoot(
                    prefix:
                        "io-fs-replace-characterize-\(candidate.rawValue)"
                )
            let manager =
                FileManager.default
            let original =
                root.appendingPathComponent(
                    "original"
                )
            let replacement =
                root.appendingPathComponent(
                    "replacement"
                )

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

            try mutationReplaceWrite(
                original,
                byte: 0x11,
                count: 4096
            )
            try manager.setAttributes(
                [
                    .posixPermissions:
                        NSNumber(
                            value: 0o600
                        ),
                    .modificationDate:
                        Date(
                            timeIntervalSince1970:
                                1_600_000_000
                        ),
                ],
                ofItemAtPath:
                    original.path
            )

            // Keep creation/inode state observably distinct.
            usleep(
                20_000
            )

            try mutationReplaceWrite(
                replacement,
                byte: 0x22,
                count: 4096
            )
            try manager.setAttributes(
                [
                    .posixPermissions:
                        NSNumber(
                            value: 0o644
                        ),
                    .modificationDate:
                        Date(
                            timeIntervalSince1970:
                                1_700_000_000
                        ),
                ],
                ofItemAtPath:
                    replacement.path
            )

            let originalBefore =
                try mutationReplaceObservation(
                    original
                )
            let replacementBefore =
                try mutationReplaceObservation(
                    replacement
                )

            let succeeded: Bool

            do {
                try mutationReplaceOperation(
                    candidate,
                    original: original,
                    replacement:
                        replacement
                )
                succeeded = true
            } catch {
                succeeded = false
                print(
                    "\(mutationReplaceCandidateName(candidate)) error: \(error)"
                )
            }

            let originalAfter =
                try mutationReplaceObservation(
                    original
                )
            let replacementAfter =
                try mutationReplaceObservation(
                    replacement
                )

            print(
                mutationReplaceCandidateName(
                    candidate
                )
            )
            print(
                "  succeeded: \(succeeded)"
            )
            print(
                "  original_content_source: "
                + mutationReplaceContentSource(
                    originalAfter,
                    originalBefore:
                        originalBefore,
                    replacementBefore:
                        replacementBefore
                )
            )
            print(
                "  original_inode_source: "
                + mutationReplaceInodeSource(
                    originalAfter,
                    originalBefore:
                        originalBefore,
                    replacementBefore:
                        replacementBefore
                )
            )
            print(
                "  original_mode_source: "
                + mutationReplaceModeSource(
                    originalAfter,
                    originalBefore:
                        originalBefore,
                    replacementBefore:
                        replacementBefore
                )
            )
            print(
                "  original_mtime_source: "
                + mutationReplaceMtimeSource(
                    originalAfter,
                    originalBefore:
                        originalBefore,
                    replacementBefore:
                        replacementBefore
                )
            )
            print(
                "  replacement_exists_after: \(replacementAfter.exists)"
            )
            print("")
        }
    }

    static func runMutationReplaceCandidateBenchmarks(
        heavy: Bool
    ) throws {
        let rounds =
            heavy
            ? 5_000
            : 500
        let sampleCount = 7
        let lanes =
            MutationReplaceCandidate.allCases
        let manager =
            FileManager.default
        let clock =
            ContinuousClock()

        print("")
        print("filesystem mutation replace candidate benchmark")
        print("case: regular-4k")
        print("heavy: \(heavy)")
        print("rounds_per_lane: \(rounds)")
        print("samples_per_lane: \(sampleCount)")
        print("lane_order: per-round rotating")
        print("lane_path_lengths: equal")
        print("setup_and_cleanup_timed: false")
        print("note: rename-only lanes are semantic lower bounds; metadata lane attempts Foundation parity")
        print("")

        var samples:
            [MutationReplaceCandidate: [Double]]
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
                        "io-fs-replace-candidates-\(sampleIndex)"
                )
            var elapsed:
                [MutationReplaceCandidate: Double]
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

                    let original =
                        laneRoot.appendingPathComponent(
                            "original"
                        )
                    let replacement =
                        laneRoot.appendingPathComponent(
                            "replacement"
                        )

                    try mutationReplaceWrite(
                        original,
                        byte: 0x11,
                        count: 4096
                    )
                    try manager.setAttributes(
                        [
                            .posixPermissions:
                                NSNumber(
                                    value: 0o600
                                ),
                        ],
                        ofItemAtPath:
                            original.path
                    )

                    try mutationReplaceWrite(
                        replacement,
                        byte: 0x22,
                        count: 4096
                    )
                    try manager.setAttributes(
                        [
                            .posixPermissions:
                                NSNumber(
                                    value: 0o644
                                ),
                        ],
                        ofItemAtPath:
                            replacement.path
                    )

                    let started =
                        clock.now

                    try mutationReplaceOperation(
                        lane,
                        original: original,
                        replacement:
                            replacement
                    )

                    elapsed[
                        lane,
                        default: 0
                    ] +=
                        mutationReplaceDurationSeconds(
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
            mutationReplaceBenchmarkSummary(
                samples[
                    .file_manager
                ] ?? []
            )

        for lane in lanes {
            let summary =
                mutationReplaceBenchmarkSummary(
                    samples[
                        lane
                    ] ?? []
                )

            print(
                mutationReplaceCandidateName(
                    lane
                )
            )
            print(
                "  seconds_per_operation_min: "
                + mutationReplaceSeconds(
                    summary.minimum
                )
            )
            print(
                "  seconds_per_operation_median: "
                + mutationReplaceSeconds(
                    summary.median
                )
            )
            print(
                "  seconds_per_operation_max: "
                + mutationReplaceSeconds(
                    summary.maximum
                )
            )
            print(
                "  vs_file_manager_x: "
                + mutationReplaceRatio(
                    baseline.median
                        / max(
                            summary.median,
                            .leastNonzeroMagnitude
                        )
                )
            )
            print("")
        }
    }

    static func mutationReplaceOperation(
        _ candidate:
            MutationReplaceCandidate,
        original: URL,
        replacement: URL
    ) throws {
        switch candidate {
        case .file_manager:
            _ = try FileManager.default.replaceItemAt(
                original,
                withItemAt:
                    replacement
            )

        case .renameat_overwrite:
            let result =
                try mutationReplaceWithFileSystemRepresentations(
                    original,
                    replacement
                ) {
                    originalPointer,
                    replacementPointer in

                    Darwin.renameat(
                        AT_FDCWD,
                        replacementPointer,
                        AT_FDCWD,
                        originalPointer
                    )
                }

            guard result == 0 else {
                throw TestFailure(
                    message:
                        "renameat replace candidate failed errno \(errno)"
                )
            }

        case .rename_swap_unlink:
            try mutationReplaceSwap(
                original: original,
                replacement:
                    replacement,
                copyMetadata: false
            )

        case .rename_swap_metadata_unlink:
            try mutationReplaceSwap(
                original: original,
                replacement:
                    replacement,
                copyMetadata: true
            )
        }
    }

    static func mutationReplaceSwap(
        original: URL,
        replacement: URL,
        copyMetadata: Bool
    ) throws {
        try mutationReplaceWithFileSystemRepresentations(
            original,
            replacement
        ) {
            originalPointer,
            replacementPointer in

            guard Darwin.renameatx_np(
                AT_FDCWD,
                replacementPointer,
                AT_FDCWD,
                originalPointer,
                UInt32(
                    RENAME_SWAP
                )
            ) == 0 else {
                throw TestFailure(
                    message:
                        "RENAME_SWAP replace candidate failed errno \(errno)"
                )
            }

            if copyMetadata {
                guard copyfile(
                    replacementPointer,
                    originalPointer,
                    nil,
                    copyfile_flags_t(
                        COPYFILE_METADATA
                    )
                ) == 0 else {
                    throw TestFailure(
                        message:
                            "COPYFILE_METADATA replace candidate failed errno \(errno)"
                    )
                }
            }

            guard Darwin.unlink(
                replacementPointer
            ) == 0 else {
                throw TestFailure(
                    message:
                        "replace candidate cleanup unlink failed errno \(errno)"
                )
            }
        }
    }

    static func mutationReplaceWithFileSystemRepresentations<Result>(
        _ original: URL,
        _ replacement: URL,
        body:
            (
                UnsafePointer<CChar>,
                UnsafePointer<CChar>
            ) throws -> Result
    ) throws -> Result {
        try original.withUnsafeFileSystemRepresentation {
            originalPointer in

            guard let originalPointer else {
                throw TestFailure(
                    message:
                        "replace candidate could not borrow original filesystem representation"
                )
            }

            return try replacement.withUnsafeFileSystemRepresentation {
                replacementPointer in

                guard let replacementPointer else {
                    throw TestFailure(
                        message:
                            "replace candidate could not borrow replacement filesystem representation"
                    )
                }

                return try body(
                    originalPointer,
                    replacementPointer
                )
            }
        }
    }

    static func mutationReplaceObservation(
        _ url: URL
    ) throws -> MutationReplaceObservation {
        var info =
            stat()

        let status =
            url.withUnsafeFileSystemRepresentation {
                pointer in

                guard let pointer else {
                    return Int32(-1)
                }

                return Darwin.lstat(
                    pointer,
                    &info
                )
            }

        if status != 0 {
            if errno == ENOENT {
                return .init(
                    exists: false,
                    mode: nil,
                    inode: nil,
                    size: nil,
                    modificationSeconds: nil,
                    bytes: nil
                )
            }

            throw TestFailure(
                message:
                    "replace observation lstat failed errno \(errno)"
            )
        }

        let type =
            info.st_mode
            & mode_t(
                S_IFMT
            )
        let bytes: [UInt8]?

        if type == mode_t(
            S_IFREG
        ) {
            bytes =
                Array(
                    try Data(
                        contentsOf: url
                    )
                )
        } else {
            bytes = nil
        }

        return .init(
            exists: true,
            mode:
                UInt32(
                    info.st_mode
                    & mode_t(
                        0o7777
                    )
                ),
            inode:
                UInt64(
                    info.st_ino
                ),
            size:
                Int64(
                    info.st_size
                ),
            modificationSeconds:
                Int64(
                    info.st_mtimespec.tv_sec
                ),
            bytes: bytes
        )
    }

    static func mutationReplaceWrite(
        _ url: URL,
        byte: UInt8,
        count: Int
    ) throws {
        try Data(
            repeating: byte,
            count: count
        ).write(
            to: url
        )
    }

    static func mutationReplaceContentSource(
        _ after:
            MutationReplaceObservation,
        originalBefore:
            MutationReplaceObservation,
        replacementBefore:
            MutationReplaceObservation
    ) -> String {
        if after.bytes
            == originalBefore.bytes
        {
            return "original"
        }

        if after.bytes
            == replacementBefore.bytes
        {
            return "replacement"
        }

        return "other"
    }

    static func mutationReplaceInodeSource(
        _ after:
            MutationReplaceObservation,
        originalBefore:
            MutationReplaceObservation,
        replacementBefore:
            MutationReplaceObservation
    ) -> String {
        if after.inode
            == originalBefore.inode
        {
            return "original"
        }

        if after.inode
            == replacementBefore.inode
        {
            return "replacement"
        }

        return "other"
    }

    static func mutationReplaceModeSource(
        _ after:
            MutationReplaceObservation,
        originalBefore:
            MutationReplaceObservation,
        replacementBefore:
            MutationReplaceObservation
    ) -> String {
        if after.mode
            == originalBefore.mode
        {
            return "original"
        }

        if after.mode
            == replacementBefore.mode
        {
            return "replacement"
        }

        return "other"
    }

    static func mutationReplaceMtimeSource(
        _ after:
            MutationReplaceObservation,
        originalBefore:
            MutationReplaceObservation,
        replacementBefore:
            MutationReplaceObservation
    ) -> String {
        if after.modificationSeconds
            == originalBefore.modificationSeconds
        {
            return "original"
        }

        if after.modificationSeconds
            == replacementBefore.modificationSeconds
        {
            return "replacement"
        }

        return "other"
    }

    static func mutationReplaceCandidateName(
        _ candidate:
            MutationReplaceCandidate
    ) -> String {
        switch candidate {
        case .file_manager:
            "file_manager"
        case .renameat_overwrite:
            "renameat_overwrite_lower_bound"
        case .rename_swap_unlink:
            "rename_swap_unlink_lower_bound"
        case .rename_swap_metadata_unlink:
            "rename_swap_copyfile_metadata_unlink"
        }
    }

    static func mutationReplaceBenchmarkSummary(
        _ values: [Double]
    ) -> MutationReplaceBenchmarkSummary {
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

    static func mutationReplaceDurationSeconds(
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

    static func mutationReplaceSeconds(
        _ value: Double
    ) -> String {
        String(
            format:
                "%.9f",
            value
        )
    }

    static func mutationReplaceRatio(
        _ value: Double
    ) -> String {
        String(
            format:
                "%.3f",
            value
        )
    }
}
#endif
