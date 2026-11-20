import Foundation
import IO

#if canImport(Darwin)
import Darwin
#endif

extension TestIO {
    static func runFileSystemMutationCopyCharacterization(heavy: Bool) throws {
        #if canImport(Darwin)
        let available = try mutationCopyCharacterizeRegularFileSemantics()
        let productionLanes = available.intersection(
            [
                .file_manager,
                .clonefile_acl,
                .clonefile_acl_nofollow,
                .production_candidate,
            ]
        )
        try mutationCopyRunRegularFileStrategyBenchmarks(
            heavy: heavy,
            available: productionLanes
        )
        try mutationTreeCopyCharacterizeAndBenchmark(
            heavy: heavy
        )
        #else
        print("filesystem mutation copy characterization is Darwin-only")
        #endif
    }
}

#if canImport(Darwin)
extension TestIO {
    enum MutationCopyCandidateLane: String, CaseIterable, Hashable {
        case file_manager
        case clonefile_acl
        case clonefile_acl_nofollow
        case production_candidate
        case copyfile_clone
        case copyfile_all
        case fcopyfile_all
        case stream_metadata
    }

    struct MutationCopyObservation: Equatable {
        let mode: UInt32?
        let modificationSeconds: Int64?
        let creationSeconds: Int64?
        let flags: UInt32?
        let finderInfo: [UInt8]?
        let spotlightComment: [UInt8]?
        let customXattr: [UInt8]?
        let acl: String?
        let bytes: [UInt8]
    }

    struct MutationCopyBenchmarkSummary {
        let minimum: Double
        let median: Double
        let maximum: Double
    }

    static func mutationCopyCharacterizeRegularFileSemantics()
        throws -> Set<MutationCopyCandidateLane>
    {
        let root = temporaryFileSystemRoot(prefix: "io-fs-copy-characterize")
        let manager = FileManager.default
        let source = root.appendingPathComponent("source.bin")
        let destination = root.appendingPathComponent("destination.bin")

        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer {
            try? manager.removeItem(at: root)
        }

        try mutationCopyPrepareSource(
            source,
            byteCount: 4096,
            includeMetadata: true
        )

        var oracle: MutationCopyObservation?
        var available = Set<MutationCopyCandidateLane>()

        print("")
        print("filesystem mutation copy regular-file characterization")
        print("oracle: FileManager.default.copyItem")
        print("candidate_scope: regular_file_only")
        print("")

        for lane in MutationCopyCandidateLane.allCases {
            try? manager.removeItem(at: destination)

            do {
                try mutationCopyRunCandidate(
                    lane,
                    source: source,
                    destination: destination
                )
                let observation = try mutationCopyObservation(destination)
                available.insert(lane)

                if lane == .file_manager {
                    oracle = observation
                    print("\(lane.rawValue)_available: true")
                    print("\(lane.rawValue)_semantic_oracle: true")
                    print("")
                    continue
                }

                guard let oracle else {
                    throw TestFailure(
                        message: "copy characterization oracle was not captured"
                    )
                }

                mutationCopyPrintSemanticComparison(
                    lane,
                    observation: observation,
                    oracle: oracle
                )
            } catch {
                if lane == .file_manager {
                    throw error
                }

                print("\(lane.rawValue)_available: false")
                print("\(lane.rawValue)_error: \(error)")
                print("")
            }
        }

        return available
    }

    static func mutationCopyRunRegularFileStrategyBenchmarks(
        heavy: Bool,
        available: Set<MutationCopyCandidateLane>
    ) throws {
        print("filesystem mutation copy regular-file strategy benchmark")
        print("oracle: FileManager.default.copyItem")
        print("setup_and_cleanup_timed: false")
        print("lane_order: rotating_counterbalanced")
        print("heavy: \(heavy)")
        print("")

        try mutationCopyRunRegularFileStrategyCase(
            name: "copy-4k-file",
            byteCount: 4 * 1024,
            rounds: heavy ? 1_000 : 100,
            available: available
        )

        try mutationCopyRunRegularFileStrategyCase(
            name: "copy-1m-file",
            byteCount: 1024 * 1024,
            rounds: heavy ? 250 : 25,
            available: available
        )

        if heavy {
            try mutationCopyRunRegularFileStrategyCase(
                name: "copy-16m-file",
                byteCount: 16 * 1024 * 1024,
                rounds: 20,
                available: available
            )
        }
    }

    static func mutationCopyRunRegularFileStrategyCase(
        name: String,
        byteCount: Int,
        rounds: Int,
        available: Set<MutationCopyCandidateLane>
    ) throws {
        let lanes = MutationCopyCandidateLane.allCases.filter {
            available.contains($0)
        }

        guard lanes.contains(.file_manager) else {
            throw TestFailure(
                message: "copy strategy benchmark has no FileManager oracle"
            )
        }

        let sampleCount = min(7, max(1, rounds))
        let baseRounds = rounds / sampleCount
        let extraRounds = rounds % sampleCount
        var samples: [MutationCopyCandidateLane: [Double]] = [:]

        for sampleIndex in 0..<sampleCount {
            let root = temporaryFileSystemRoot(
                prefix: "io-fs-copy-\(name)-sample-\(sampleIndex)"
            )
            let manager = FileManager.default
            let source = root.appendingPathComponent("source.bin")
            let destination = root.appendingPathComponent("destination.bin")
            let sampleRounds =
                baseRounds + (sampleIndex < extraRounds ? 1 : 0)

            try manager.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            defer {
                try? manager.removeItem(at: root)
            }

            try mutationCopyPrepareSource(
                source,
                byteCount: byteCount,
                includeMetadata: true
            )

            for lane in mutationCopyRotatedLanes(
                lanes,
                offset: sampleIndex
            ) {
                let seconds = try mutationCopyMeasureCandidate(
                    lane,
                    rounds: sampleRounds,
                    source: source,
                    destination: destination
                )

                samples[lane, default: []].append(
                    seconds / Double(sampleRounds)
                )
            }
        }

        let fileManager = mutationCopyBenchmarkSummary(
            samples[.file_manager] ?? []
        )

        print(name)
        print("  bytes: \(byteCount)")
        print("  rounds_per_lane: \(rounds)")
        print("  samples_per_lane: \(sampleCount)")

        for lane in lanes {
            let summary = mutationCopyBenchmarkSummary(
                samples[lane] ?? []
            )
            mutationCopyPrintBenchmarkSummary(
                lane,
                summary: summary
            )

            if lane != .file_manager {
                print(
                    "  \(lane.rawValue)_vs_file_manager_x: "
                    + mutationCopyFormattedRatio(
                        fileManager.median
                            / max(
                                summary.median,
                                .leastNonzeroMagnitude
                            )
                    )
                )
            }
        }

        print("")
    }

    static func mutationCopyMeasureCandidate(
        _ lane: MutationCopyCandidateLane,
        rounds: Int,
        source: URL,
        destination: URL
    ) throws -> Double {
        let manager = FileManager.default
        let clock = ContinuousClock()
        var wallSeconds = 0.0

        for _ in 0..<rounds {
            try? manager.removeItem(at: destination)

            let started = clock.now
            try mutationCopyRunCandidate(
                lane,
                source: source,
                destination: destination
            )
            wallSeconds += mutationCopyDurationSeconds(
                started.duration(to: clock.now)
            )

            try manager.removeItem(at: destination)
        }

        return wallSeconds
    }

    static func mutationCopyRunCandidate(
        _ lane: MutationCopyCandidateLane,
        source: URL,
        destination: URL
    ) throws {
        switch lane {
        case .file_manager:
            try FileManager.default.copyItem(
                at: source,
                to: destination
            )

        case .clonefile_acl:
            try mutationCopyClonefile(
                source,
                destination: destination,
                flags: UInt32(CLONE_ACL)
            )

        case .clonefile_acl_nofollow:
            try mutationCopyClonefile(
                source,
                destination: destination,
                flags:
                    UInt32(CLONE_ACL)
                    | UInt32(CLONE_NOFOLLOW)
            )

        case .production_candidate:
            try mutationCopyProductionCandidate(
                source,
                destination: destination
            )

        case .copyfile_clone:
            try mutationCopyCopyfile(
                source,
                destination: destination,
                flags: copyfile_flags_t(
                    COPYFILE_ALL | COPYFILE_CLONE
                )
            )

        case .copyfile_all:
            try mutationCopyCopyfile(
                source,
                destination: destination,
                flags: copyfile_flags_t(
                    COPYFILE_ALL
                    | COPYFILE_EXCL
                    | COPYFILE_NOFOLLOW_SRC
                )
            )

        case .fcopyfile_all:
            try mutationCopyFcopyfile(
                source,
                destination: destination
            )

        case .stream_metadata:
            try mutationCopyStreamAndMetadata(
                source,
                destination: destination
            )
        }
    }

    static func mutationCopyClonefile(
        _ source: URL,
        destination: URL,
        flags: UInt32
    ) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePointer in
            guard let sourcePointer else {
                return Int32(-1)
            }

            return destination.withUnsafeFileSystemRepresentation {
                destinationPointer in

                guard let destinationPointer else {
                    return Int32(-1)
                }

                return Darwin.clonefile(
                    sourcePointer,
                    destinationPointer,
                    flags
                )
            }
        }

        guard result == 0 else {
            throw TestFailure(
                message: "clonefile copy candidate failed errno \(errno)"
            )
        }
    }

    static func mutationCopyProductionCandidate(
        _ source: URL,
        destination: URL
    ) throws {
        let cloned = source.withUnsafeFileSystemRepresentation {
            sourcePointer in

            guard let sourcePointer else {
                return false
            }

            var info = stat()
            guard Darwin.lstat(
                sourcePointer,
                &info
            ) == 0 else {
                return false
            }

            let kind =
                info.st_mode
                & mode_t(S_IFMT)

            guard kind == mode_t(S_IFREG) else {
                return false
            }

            return destination.withUnsafeFileSystemRepresentation {
                destinationPointer in

                guard let destinationPointer else {
                    return false
                }

                return Darwin.clonefile(
                    sourcePointer,
                    destinationPointer,
                    UInt32(CLONE_ACL)
                        | UInt32(CLONE_NOFOLLOW)
                ) == 0
            }
        }

        if cloned {
            return
        }

        try FileManager.default.copyItem(
            at: source.standardizedFileURL,
            to: destination.standardizedFileURL
        )
    }

    static func mutationCopyCopyfile(
        _ source: URL,
        destination: URL,
        flags: copyfile_flags_t
    ) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePointer in
            guard let sourcePointer else {
                return Int32(-1)
            }

            return destination.withUnsafeFileSystemRepresentation {
                destinationPointer in

                guard let destinationPointer else {
                    return Int32(-1)
                }

                return copyfile(
                    sourcePointer,
                    destinationPointer,
                    nil,
                    flags
                )
            }
        }

        guard result == 0 else {
            throw TestFailure(
                message: "copyfile copy candidate failed errno \(errno)"
            )
        }
    }

    static func mutationCopyFcopyfile(
        _ source: URL,
        destination: URL
    ) throws {
        let sourceDescriptor = source.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                return Int32(-1)
            }

            return Darwin.open(pointer, O_RDONLY)
        }

        guard sourceDescriptor >= 0 else {
            throw TestFailure(
                message: "fcopyfile source open failed errno \(errno)"
            )
        }
        defer {
            _ = Darwin.close(sourceDescriptor)
        }

        let destinationDescriptor =
            destination.withUnsafeFileSystemRepresentation { pointer in
                guard let pointer else {
                    return Int32(-1)
                }

                return Darwin.open(
                    pointer,
                    O_WRONLY | O_CREAT | O_EXCL,
                    mode_t(0o600)
                )
            }

        guard destinationDescriptor >= 0 else {
            throw TestFailure(
                message: "fcopyfile destination open failed errno \(errno)"
            )
        }
        defer {
            _ = Darwin.close(destinationDescriptor)
        }

        guard fcopyfile(
            sourceDescriptor,
            destinationDescriptor,
            nil,
            copyfile_flags_t(
                COPYFILE_ALL
            )
        ) == 0 else {
            throw TestFailure(
                message: "fcopyfile copy candidate failed errno \(errno)"
            )
        }
    }

    static func mutationCopyStreamAndMetadata(
        _ source: URL,
        destination: URL
    ) throws {
        do {
            var input = Source(
                try SystemFileSource(path: source.path)
            )
            var output = Destination(
                try SystemFileDestination(
                    path: destination.path,
                    mode: .create
                )
            )

            let result = try input.stream(to: &output)
            guard case .end = result else {
                throw TestFailure(
                    message:
                        "Source->Destination copy candidate did not reach EOF: \(result)"
                )
            }

            guard try output.flush() == .complete else {
                throw TestFailure(
                    message:
                        "Source->Destination copy candidate could not flush"
                )
            }
        }

        try mutationCopyCopyfile(
            source,
            destination: destination,
            flags: copyfile_flags_t(
                COPYFILE_METADATA
            )
        )
    }

    static func mutationCopyPrepareSource(
        _ source: URL,
        byteCount: Int,
        includeMetadata: Bool
    ) throws {
        let manager = FileManager.default

        try Data(
            repeating: 0x5a,
            count: byteCount
        ).write(to: source)

        guard includeMetadata else {
            return
        }

        try manager.setAttributes(
            [
                .posixPermissions: NSNumber(value: 0o640),
                .modificationDate:
                    Date(timeIntervalSince1970: 1_700_000_000),
                .creationDate:
                    Date(timeIntervalSince1970: 1_600_000_000),
            ],
            ofItemAtPath: source.path
        )

        try mutationReplaceSetFlags(
            source,
            flags: UInt32(UF_HIDDEN)
        )

        var finderInfo = [UInt8](
            repeating: 0,
            count: 32
        )
        finderInfo[0] = 0x33
        finderInfo[9] = 0x0A
        finderInfo[31] = 0x44

        try mutationReplaceSetXattr(
            source,
            name: mutationReplaceFinderInfoXattr,
            bytes: finderInfo
        )
        try mutationReplaceSetXattr(
            source,
            name: mutationReplaceSpotlightCommentXattr,
            bytes: Array("copy-comment".utf8)
        )
        try mutationReplaceSetXattr(
            source,
            name: mutationReplaceCustomXattr,
            bytes: Array("copy-custom".utf8)
        )
        try replaceACLAddEntry(
            "everyone allow read",
            to: source
        )
    }

    static func mutationCopyObservation(
        _ url: URL
    ) throws -> MutationCopyObservation {
        let metadata = try mutationReplaceMetadataObservation(url)

        guard metadata.exists else {
            throw TestFailure(
                message: "copy characterization destination is missing"
            )
        }

        return .init(
            mode: metadata.mode,
            modificationSeconds: metadata.modificationSeconds,
            creationSeconds: metadata.creationSeconds,
            flags: metadata.flags,
            finderInfo: metadata.finderInfo,
            spotlightComment: metadata.spotlightComment,
            customXattr: metadata.customXattr,
            acl: try replaceACLText(url),
            bytes: Array(try Data(contentsOf: url))
        )
    }

    static func mutationCopyPrintSemanticComparison(
        _ lane: MutationCopyCandidateLane,
        observation: MutationCopyObservation,
        oracle: MutationCopyObservation
    ) {
        print("\(lane.rawValue)_available: true")
        print("\(lane.rawValue)_bytes_match: \(observation.bytes == oracle.bytes)")
        print("\(lane.rawValue)_mode_match: \(observation.mode == oracle.mode)")
        print(
            "\(lane.rawValue)_mtime_match: "
            + "\(observation.modificationSeconds == oracle.modificationSeconds)"
        )
        print(
            "\(lane.rawValue)_creation_time_match: "
            + "\(observation.creationSeconds == oracle.creationSeconds)"
        )
        print("\(lane.rawValue)_bsd_flags_match: \(observation.flags == oracle.flags)")
        print(
            "\(lane.rawValue)_finder_info_match: "
            + "\(observation.finderInfo == oracle.finderInfo)"
        )
        print(
            "\(lane.rawValue)_spotlight_comment_match: "
            + "\(observation.spotlightComment == oracle.spotlightComment)"
        )
        print(
            "\(lane.rawValue)_custom_xattr_match: "
            + "\(observation.customXattr == oracle.customXattr)"
        )
        print("\(lane.rawValue)_acl_match: \(observation.acl == oracle.acl)")
        print("\(lane.rawValue)_semantic_equivalent: \(observation == oracle)")
        print("")
    }

    static func mutationCopyRotatedLanes(
        _ lanes: [MutationCopyCandidateLane],
        offset: Int
    ) -> [MutationCopyCandidateLane] {
        guard !lanes.isEmpty else {
            return []
        }

        let normalized = offset % lanes.count
        return Array(lanes[normalized...])
            + Array(lanes[..<normalized])
    }

    static func mutationCopyBenchmarkSummary(
        _ samples: [Double]
    ) -> MutationCopyBenchmarkSummary {
        precondition(!samples.isEmpty)

        let sorted = samples.sorted()
        let middle = sorted.count / 2
        let median: Double

        if sorted.count.isMultiple(of: 2) {
            median = (sorted[middle - 1] + sorted[middle]) / 2
        } else {
            median = sorted[middle]
        }

        return .init(
            minimum: sorted[0],
            median: median,
            maximum: sorted[sorted.count - 1]
        )
    }

    static func mutationCopyPrintBenchmarkSummary(
        _ lane: MutationCopyCandidateLane,
        summary: MutationCopyBenchmarkSummary
    ) {
        print(
            "  \(lane.rawValue)_seconds_per_operation_min: "
            + mutationCopyFormattedOperationSeconds(summary.minimum)
        )
        print(
            "  \(lane.rawValue)_seconds_per_operation_median: "
            + mutationCopyFormattedOperationSeconds(summary.median)
        )
        print(
            "  \(lane.rawValue)_seconds_per_operation_max: "
            + mutationCopyFormattedOperationSeconds(summary.maximum)
        )
    }

    static func mutationCopyDurationSeconds(
        _ duration: Duration
    ) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds)
                / 1_000_000_000_000_000_000
    }

    static func mutationCopyFormattedOperationSeconds(
        _ value: Double
    ) -> String {
        if value < 0.001 {
            return String(
                format: "%.3f us",
                value * 1_000_000
            )
        }

        return String(
            format: "%.3f ms",
            value * 1_000
        )
    }

    static func mutationCopyFormattedRatio(
        _ value: Double
    ) -> String {
        String(format: "%.3f", value)
    }
}
#endif
