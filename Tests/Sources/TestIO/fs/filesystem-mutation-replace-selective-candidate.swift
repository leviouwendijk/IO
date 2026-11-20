import Foundation
import IO

#if canImport(Darwin)
import Darwin
#endif

extension TestIO {
    enum MutationReplaceSelectiveCandidate:
        Int,
        CaseIterable,
        Hashable
    {
        case file_manager
        #if canImport(Darwin)
        case swap_mode_birthtime_unlink
        #endif
    }

    struct MutationReplaceSelectiveSummary {
        let minimum: Double
        let median: Double
        let maximum: Double
    }

    static func runFileSystemMutationReplaceSelectiveCandidate(
        heavy: Bool
    ) throws {
        #if canImport(Darwin)
        try characterizeMutationReplaceACL()
        try characterizeMutationReplaceSelectiveCandidate()
        try benchmarkMutationReplaceSelectiveCandidate(
            heavy: heavy
        )
        #else
        print(
            "filesystem mutation replace selective candidate is Darwin-only"
        )
        #endif
    }
}

#if canImport(Darwin)
extension TestIO {
    static func characterizeMutationReplaceACL() throws {
        let root =
            temporaryFileSystemRoot(
                prefix:
                    "io-fs-replace-acl-characterize"
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

        try Data(
            repeating: 0x11,
            count: 128
        ).write(
            to: original
        )
        try Data(
            repeating: 0x22,
            count: 128
        ).write(
            to: replacement
        )

        try mutationReplaceAddACLEntry(
            "everyone allow read",
            to: original
        )
        try mutationReplaceAddACLEntry(
            "everyone allow read,readattr",
            to: replacement
        )

        let originalBefore =
            try mutationReplaceACLText(
                original
            )
        let replacementBefore =
            try mutationReplaceACLText(
                replacement
            )

        _ = try manager.replaceItemAt(
            original,
            withItemAt:
                replacement
        )

        let after =
            try mutationReplaceACLText(
                original
            )

        let source: String

        if after == originalBefore {
            source = "original"
        } else if after == replacementBefore {
            source = "replacement"
        } else if after.isEmpty {
            source = "empty"
        } else {
            source = "other"
        }

        print("")
        print("filesystem mutation replace ACL characterization")
        print("oracle: FileManager.default.replaceItemAt default options")
        print("")
        print(
            "original_acl: \(originalBefore)"
        )
        print(
            "replacement_acl: \(replacementBefore)"
        )
        print(
            "result_acl: \(after)"
        )
        print(
            "acl_source: \(source)"
        )
        print("")
    }

    static func characterizeMutationReplaceSelectiveCandidate() throws {
        let manager =
            FileManager.default

        for candidate in MutationReplaceSelectiveCandidate.allCases {
            let root =
                temporaryFileSystemRoot(
                    prefix:
                        "io-fs-replace-selective-characterize-\(candidate.rawValue)"
                )
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

            try Data(
                repeating: 0x11,
                count: 4096
            ).write(
                to: original
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
                    .creationDate:
                        Date(
                            timeIntervalSince1970:
                                1_500_000_000
                        ),
                ],
                ofItemAtPath:
                    original.path
            )

            try Data(
                repeating: 0x22,
                count: 4096
            ).write(
                to: replacement
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
                    .creationDate:
                        Date(
                            timeIntervalSince1970:
                                1_750_000_000
                        ),
                ],
                ofItemAtPath:
                    replacement.path
            )

            let originalBefore =
                try mutationReplaceSelectiveObservation(
                    original
                )
            let replacementBefore =
                try mutationReplaceSelectiveObservation(
                    replacement
                )

            try mutationReplaceSelectiveOperation(
                candidate,
                original: original,
                replacement:
                    replacement
            )

            let after =
                try mutationReplaceSelectiveObservation(
                    original
                )
            let replacementAfter =
                try mutationReplaceSelectiveObservation(
                    replacement
                )

            print(
                "filesystem mutation replace selective characterization"
            )
            print(
                "candidate: \(mutationReplaceSelectiveCandidateName(candidate))"
            )
            print(
                "  content_source: "
                + mutationReplaceSelectiveSource(
                    after.bytes,
                    original:
                        originalBefore.bytes,
                    replacement:
                        replacementBefore.bytes
                )
            )
            print(
                "  inode_source: "
                + mutationReplaceSelectiveSource(
                    after.inode,
                    original:
                        originalBefore.inode,
                    replacement:
                        replacementBefore.inode
                )
            )
            print(
                "  mode_source: "
                + mutationReplaceSelectiveSource(
                    after.mode,
                    original:
                        originalBefore.mode,
                    replacement:
                        replacementBefore.mode
                )
            )
            print(
                "  mtime_source: "
                + mutationReplaceSelectiveSource(
                    after.modificationSeconds,
                    original:
                        originalBefore.modificationSeconds,
                    replacement:
                        replacementBefore.modificationSeconds
                )
            )
            print(
                "  creation_time_source: "
                + mutationReplaceSelectiveSource(
                    after.creationSeconds,
                    original:
                        originalBefore.creationSeconds,
                    replacement:
                        replacementBefore.creationSeconds
                )
            )
            print(
                "  replacement_exists_after: \(replacementAfter.exists)"
            )
            print("")
        }
    }

    static func benchmarkMutationReplaceSelectiveCandidate(
        heavy: Bool
    ) throws {
        let rounds =
            heavy
            ? 5_000
            : 500
        let sampleCount = 7
        let lanes =
            MutationReplaceSelectiveCandidate.allCases
        let manager =
            FileManager.default
        let clock =
            ContinuousClock()
        var samples:
            [MutationReplaceSelectiveCandidate: [Double]]
            = [:]

        print("filesystem mutation replace selective benchmark")
        print("case: regular-4k")
        print("heavy: \(heavy)")
        print("rounds_per_lane: \(rounds)")
        print("samples_per_lane: \(sampleCount)")
        print("lane_order: per-round rotating")
        print("lane_path_lengths: equal")
        print("setup_and_cleanup_timed: false")
        print("")

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
                        "io-fs-replace-selective-bench-\(sampleIndex)"
                )
            var elapsed:
                [MutationReplaceSelectiveCandidate: Double]
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
                    let original =
                        laneRoot.appendingPathComponent(
                            "original"
                        )
                    let replacement =
                        laneRoot.appendingPathComponent(
                            "replacement"
                        )

                    try manager.createDirectory(
                        at: laneRoot,
                        withIntermediateDirectories:
                            false
                    )

                    try Data(
                        repeating: 0x11,
                        count: 4096
                    ).write(
                        to: original
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

                    try Data(
                        repeating: 0x22,
                        count: 4096
                    ).write(
                        to: replacement
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

                    try mutationReplaceSelectiveOperation(
                        lane,
                        original: original,
                        replacement:
                            replacement
                    )

                    elapsed[
                        lane,
                        default: 0
                    ] +=
                        mutationReplaceSelectiveDurationSeconds(
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
            mutationReplaceSelectiveSummary(
                samples[
                    .file_manager
                ] ?? []
            )

        for lane in lanes {
            let summary =
                mutationReplaceSelectiveSummary(
                    samples[
                        lane
                    ] ?? []
                )

            print(
                mutationReplaceSelectiveCandidateName(
                    lane
                )
            )
            print(
                "  seconds_per_operation_min: "
                + mutationReplaceSelectiveSeconds(
                    summary.minimum
                )
            )
            print(
                "  seconds_per_operation_median: "
                + mutationReplaceSelectiveSeconds(
                    summary.median
                )
            )
            print(
                "  seconds_per_operation_max: "
                + mutationReplaceSelectiveSeconds(
                    summary.maximum
                )
            )
            print(
                "  vs_file_manager_x: "
                + mutationReplaceSelectiveRatio(
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

    static func mutationReplaceSelectiveOperation(
        _ candidate:
            MutationReplaceSelectiveCandidate,
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

        case .swap_mode_birthtime_unlink:
            try mutationReplaceSelectiveNative(
                original: original,
                replacement:
                    replacement
            )
        }
    }

    static func mutationReplaceSelectiveNative(
        original: URL,
        replacement: URL
    ) throws {
        var originalInfo =
            stat()

        try original.withUnsafeFileSystemRepresentation {
            originalPointer in

            guard let originalPointer else {
                throw TestFailure(
                    message:
                        "replace selective original path borrow failed"
                )
            }

            guard Darwin.lstat(
                originalPointer,
                &originalInfo
            ) == 0 else {
                throw TestFailure(
                    message:
                        "replace selective original lstat failed errno \(errno)"
                )
            }

            try replacement.withUnsafeFileSystemRepresentation {
                replacementPointer in

                guard let replacementPointer else {
                    throw TestFailure(
                        message:
                            "replace selective replacement path borrow failed"
                    )
                }

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
                            "replace selective RENAME_SWAP failed errno \(errno)"
                    )
                }

                guard Darwin.chmod(
                    originalPointer,
                    originalInfo.st_mode
                        & mode_t(
                            0o7777
                        )
                ) == 0 else {
                    throw TestFailure(
                        message:
                            "replace selective chmod failed errno \(errno)"
                    )
                }

                var attributes =
                    attrlist()
                attributes.bitmapcount =
                    UInt16(
                        ATTR_BIT_MAP_COUNT
                    )
                attributes.commonattr =
                    attrgroup_t(
                        ATTR_CMN_CRTIME
                    )

                var creationTime =
                    originalInfo.st_birthtimespec

                guard setattrlist(
                    originalPointer,
                    &attributes,
                    &creationTime,
                    MemoryLayout<
                        timespec
                    >.size,
                    UInt32(
                        FSOPT_NOFOLLOW
                    )
                ) == 0 else {
                    throw TestFailure(
                        message:
                            "replace selective creation-time setattrlist failed errno \(errno)"
                    )
                }

                guard Darwin.unlink(
                    replacementPointer
                ) == 0 else {
                    throw TestFailure(
                        message:
                            "replace selective unlink failed errno \(errno)"
                    )
                }
            }
        }
    }

    static func mutationReplaceSelectiveObservation(
        _ url: URL
    ) throws -> (
        exists: Bool,
        mode: UInt32?,
        inode: UInt64?,
        modificationSeconds: Int64?,
        creationSeconds: Int64?,
        bytes: [UInt8]?
    ) {
        var info =
            stat()

        let result =
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

        if result != 0 {
            if errno == ENOENT {
                return (
                    false,
                    nil,
                    nil,
                    nil,
                    nil,
                    nil
                )
            }

            throw TestFailure(
                message:
                    "replace selective observation lstat failed errno \(errno)"
            )
        }

        return (
            true,
            UInt32(
                info.st_mode
                    & mode_t(
                        0o7777
                    )
            ),
            UInt64(
                info.st_ino
            ),
            Int64(
                info.st_mtimespec.tv_sec
            ),
            Int64(
                info.st_birthtimespec.tv_sec
            ),
            Array(
                try Data(
                    contentsOf: url
                )
            )
        )
    }

    static func mutationReplaceAddACLEntry(
        _ entry: String,
        to url: URL
    ) throws {
        let process =
            Process()
        process.executableURL =
            URL(
                fileURLWithPath:
                    "/bin/chmod"
            )
        process.arguments =
            [
                "+a",
                entry,
                url.path,
            ]

        let errorPipe =
            Pipe()
        process.standardError =
            errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let bytes =
                errorPipe
                    .fileHandleForReading
                    .readDataToEndOfFile()
            let message =
                String(
                    data: bytes,
                    encoding: .utf8
                ) ?? ""

            throw TestFailure(
                message:
                    "replace ACL setup failed: \(message)"
            )
        }
    }

    static func mutationReplaceACLText(
        _ url: URL
    ) throws -> String {
        try url.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                throw TestFailure(
                    message:
                        "replace ACL path borrow failed"
                )
            }

            guard let acl =
                    acl_get_file(
                        pointer,
                        ACL_TYPE_EXTENDED
                    )
            else {
                if errno == ENOENT {
                    return ""
                }

                throw TestFailure(
                    message:
                        "replace ACL read failed errno \(errno)"
                )
            }

            defer {
                _ = acl_free(
                    UnsafeMutableRawPointer(
                        acl
                    )
                )
            }

            var length:
                ssize_t = 0

            guard let textPointer =
                    acl_to_text(
                        acl,
                        &length
                    )
            else {
                throw TestFailure(
                    message:
                        "replace ACL text conversion failed errno \(errno)"
                )
            }

            defer {
                _ = acl_free(
                    UnsafeMutableRawPointer(
                        textPointer
                    )
                )
            }

            return String(
                cString:
                    textPointer
            )
        }
    }

    static func mutationReplaceSelectiveSource<Value: Equatable>(
        _ after: Value?,
        original: Value?,
        replacement: Value?
    ) -> String {
        if after == original {
            return "original"
        }

        if after == replacement {
            return "replacement"
        }

        if after == nil {
            return "missing"
        }

        return "other"
    }

    static func mutationReplaceSelectiveCandidateName(
        _ candidate:
            MutationReplaceSelectiveCandidate
    ) -> String {
        switch candidate {
        case .file_manager:
            "file_manager"
        case .swap_mode_birthtime_unlink:
            "rename_swap_mode_birthtime_unlink"
        }
    }

    static func mutationReplaceSelectiveSummary(
        _ values: [Double]
    ) -> MutationReplaceSelectiveSummary {
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

    static func mutationReplaceSelectiveDurationSeconds(
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

    static func mutationReplaceSelectiveSeconds(
        _ value: Double
    ) -> String {
        String(
            format:
                "%.9f",
            value
        )
    }

    static func mutationReplaceSelectiveRatio(
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
