import Foundation
import IO

#if canImport(Darwin)
import Darwin

extension TestIO {
    enum MutationTreeCopyCandidateLane: String, CaseIterable, Hashable {
        case file_manager
        case copyfile_recursive_clone
        case copyfile_recursive_all
        case clonefile_directory
        case native_fd_walker
    }

    enum MutationTreeCopyEntryKind: String, Equatable {
        case directory
        case regular_file
        case symbolic_link
        case other
    }

    struct MutationTreeCopyEntryObservation: Equatable {
        let relativePath: String
        let kind: MutationTreeCopyEntryKind
        let mode: UInt32
        let modificationSeconds: Int64
        let creationSeconds: Int64
        let flags: UInt32
        let finderInfo: [UInt8]?
        let spotlightComment: [UInt8]?
        let customXattr: [UInt8]?
        let acl: String?
        let bytes: [UInt8]?
        let symbolicLinkTarget: String?
        let hardLinkGroup: Int?
    }

    struct MutationTreeCopySemanticEntry: Equatable {
        let relativePath: String
        let kind: MutationTreeCopyEntryKind
        let mode: UInt32
        let modificationPreserved: Bool
        let creationPreserved: Bool
        let flags: UInt32
        let finderInfo: [UInt8]?
        let spotlightComment: [UInt8]?
        let customXattr: [UInt8]?
        let acl: String?
        let bytes: [UInt8]?
        let symbolicLinkTarget: String?
        let hardLinkGroup: Int?
    }

    struct MutationTreeCopyNamespaceEntry: Equatable {
        let relativePath: String
        let kind: MutationTreeCopyEntryKind
        let bytes: [UInt8]?
        let symbolicLinkTarget: String?
    }

    struct MutationTreeCopyFailureObservation: Equatable {
        let succeeded: Bool
        let sourceUnchanged: Bool
        let destination: [MutationTreeCopyNamespaceEntry]?
    }

    enum MutationTreeCopyFailureScenario: String, CaseIterable {
        case existing_file
        case existing_directory
        case missing_parent
    }

    enum MutationTreeCopyInjectedFailure: Error {
        case requested
    }

    struct MutationTreeCopyNativeFailureState {
        let failAfterCopiedEntries: Int?
        var copiedEntryCount: Int = 0

        mutating func recordCopiedEntry() throws {
            copiedEntryCount += 1

            guard let failAfterCopiedEntries,
                  copiedEntryCount >= failAfterCopiedEntries
            else {
                return
            }

            throw MutationTreeCopyInjectedFailure.requested
        }
    }

    static func mutationTreeCopyCharacterizeAndBenchmark(heavy: Bool) throws {
        let successEquivalent = try mutationTreeCopyCharacterizeSuccessSemantics()
        let failureEquivalent = try mutationTreeCopyCharacterizeFailureSemantics()
        let rollbackEquivalent = try mutationTreeCopyCharacterizeInjectedRollback()

        var viable = successEquivalent.intersection(failureEquivalent)
        if !rollbackEquivalent {
            viable.remove(.native_fd_walker)
        }

        print("filesystem mutation copy tree viable candidates")
        for lane in MutationTreeCopyCandidateLane.allCases {
            print("\(lane.rawValue)_viable: \(viable.contains(lane))")
        }
        print("")

        try mutationTreeCopyRunStrategyBenchmark(
            heavy: heavy,
            viable: viable
        )
    }

    static func mutationTreeCopyCharacterizeSuccessSemantics()
        throws -> Set<MutationTreeCopyCandidateLane>
    {
        let root = temporaryFileSystemRoot(prefix: "io-fs-copy-tree-characterize")
        let manager = FileManager.default
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)

        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        try mutationTreeCopyPrepareRichTree(source)

        var oracle: [MutationTreeCopySemanticEntry]?
        var equivalent = Set<MutationTreeCopyCandidateLane>()

        print("")
        print("filesystem mutation copy directory-tree characterization")
        print("oracle: FileManager.default.copyItem")
        print("candidate_scope: recursive_directory_tree")
        print("fixture: directories regular_files file_symlink directory_symlink broken_symlink hard_links metadata")
        print("metadata: mode mtime creation_time bsd_flags FinderInfo Finder_comment custom_xattr ACL")
        print("clonefile_directory_role: characterization_ceiling_only")
        print("native_fd_walker_role: retained_fd_candidate")
        print("")

        for lane in MutationTreeCopyCandidateLane.allCases {
            try? manager.removeItem(at: destination)

            do {
                try mutationTreeCopyRunCandidate(
                    lane,
                    source: source,
                    destination: destination
                )
                let observation = try mutationTreeCopySemanticObservation(
                    source: source,
                    destination: destination
                )

                if lane == .file_manager {
                    oracle = observation
                    equivalent.insert(lane)
                    print("\(lane.rawValue)_available: true")
                    print("\(lane.rawValue)_semantic_oracle: true")
                    print("\(lane.rawValue)_entry_count: \(observation.count)")
                    mutationTreeCopyPrintDirectoryPreservation(
                        lane: lane,
                        observation: observation
                    )
                    print("")
                    continue
                }

                guard let oracle else {
                    throw TestFailure(message: "tree copy characterization oracle was not captured")
                }

                let isEquivalent = observation == oracle
                if isEquivalent {
                    equivalent.insert(lane)
                }

                print("\(lane.rawValue)_available: true")
                print("\(lane.rawValue)_structure_match: \(mutationTreeCopyStructureMatches(observation, oracle))")
                print("\(lane.rawValue)_metadata_match: \(mutationTreeCopyMetadataMatches(observation, oracle))")
                print("\(lane.rawValue)_content_and_symlink_match: \(mutationTreeCopyPayloadMatches(observation, oracle))")
                print("\(lane.rawValue)_hard_link_topology_match: \(mutationTreeCopyHardLinkMatches(observation, oracle))")
                print("\(lane.rawValue)_semantic_equivalent: \(isEquivalent)")
                mutationTreeCopyPrintDirectoryPreservation(
                    lane: lane,
                    observation: observation
                )
                if let difference = mutationTreeCopyFirstDifference(observation, oracle) {
                    print("\(lane.rawValue)_first_difference: \(difference)")
                }
                print("")
            } catch {
                if lane == .file_manager {
                    throw error
                }
                print("\(lane.rawValue)_available: false")
                print("\(lane.rawValue)_error: \(error)")
                print("\(lane.rawValue)_semantic_equivalent: false")
                print("")
            }
        }

        return equivalent
    }

    static func mutationTreeCopyCharacterizeFailureSemantics()
        throws -> Set<MutationTreeCopyCandidateLane>
    {
        var equivalent = Set(MutationTreeCopyCandidateLane.allCases)

        print("filesystem mutation copy directory-tree failure characterization")
        print("oracle: FileManager.default.copyItem")
        print("scenarios: existing_file existing_directory missing_parent")
        print("")

        for scenario in MutationTreeCopyFailureScenario.allCases {
            var oracle: MutationTreeCopyFailureObservation?
            print("scenario: \(scenario.rawValue)")

            for lane in MutationTreeCopyCandidateLane.allCases {
                let observation = try mutationTreeCopyFailureObservation(
                    lane: lane,
                    scenario: scenario
                )

                if lane == .file_manager {
                    oracle = observation
                    print("\(lane.rawValue)_succeeded: \(observation.succeeded)")
                    print("\(lane.rawValue)_source_unchanged: \(observation.sourceUnchanged)")
                    continue
                }

                guard let oracle else {
                    throw TestFailure(message: "tree copy failure oracle was not captured")
                }

                let matches = observation == oracle
                if !matches {
                    equivalent.remove(lane)
                }

                print("\(lane.rawValue)_succeeded_match: \(observation.succeeded == oracle.succeeded)")
                print("\(lane.rawValue)_source_unchanged_match: \(observation.sourceUnchanged == oracle.sourceUnchanged)")
                print("\(lane.rawValue)_destination_state_match: \(observation.destination == oracle.destination)")
                print("\(lane.rawValue)_semantic_equivalent: \(matches)")
            }
            print("")
        }

        return equivalent
    }

    static func mutationTreeCopyFailureObservation(
        lane: MutationTreeCopyCandidateLane,
        scenario: MutationTreeCopyFailureScenario
    ) throws -> MutationTreeCopyFailureObservation {
        let root = temporaryFileSystemRoot(
            prefix: "io-fs-copy-tree-failure-\(scenario.rawValue)-\(lane.rawValue)"
        )
        let manager = FileManager.default
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination: URL

        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        try mutationTreeCopyPrepareFailureSource(source)

        switch scenario {
        case .existing_file:
            destination = root.appendingPathComponent("destination")
            try Data("existing-destination".utf8).write(to: destination)
        case .existing_directory:
            destination = root.appendingPathComponent("destination", isDirectory: true)
            try manager.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("keep".utf8).write(
                to: destination.appendingPathComponent("sentinel.txt")
            )
        case .missing_parent:
            destination = root
                .appendingPathComponent("missing-parent", isDirectory: true)
                .appendingPathComponent("destination", isDirectory: true)
        }

        let sourceBefore = try mutationTreeCopyNamespaceObservation(source)

        let succeeded: Bool
        do {
            try mutationTreeCopyRunCandidate(
                lane,
                source: source,
                destination: destination
            )
            succeeded = true
        } catch {
            succeeded = false
        }

        let sourceAfter = try mutationTreeCopyNamespaceObservation(source)
        let destinationObservation: [MutationTreeCopyNamespaceEntry]?
        if mutationTreeCopyPathExists(destination) {
            destinationObservation = try mutationTreeCopyNamespaceObservation(destination)
        } else {
            destinationObservation = nil
        }

        return .init(
            succeeded: succeeded,
            sourceUnchanged: sourceBefore == sourceAfter,
            destination: destinationObservation
        )
    }

    static func mutationTreeCopyCharacterizeInjectedRollback() throws -> Bool {
        let root = temporaryFileSystemRoot(
            prefix: "io-fs-copy-tree-injected-rollback"
        )
        let manager = FileManager.default
        let source = root.appendingPathComponent(
            "source",
            isDirectory: true
        )
        let destination = root.appendingPathComponent(
            "destination",
            isDirectory: true
        )

        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer {
            try? manager.removeItem(at: root)
        }

        try mutationTreeCopyPrepareFailureSource(source)

        let sourceBefore =
            try mutationTreeCopyNamespaceObservation(source)

        var observedInjectedFailure = false
        var unexpectedError: String?

        do {
            try mutationTreeCopyNativeFDWalker(
                source: source,
                destination: destination,
                failureAfterCopiedEntries: 3
            )
        } catch is MutationTreeCopyInjectedFailure {
            observedInjectedFailure = true
        } catch {
            unexpectedError = String(describing: error)
        }

        let sourceAfter =
            try mutationTreeCopyNamespaceObservation(source)
        let sourceUnchanged =
            sourceBefore == sourceAfter
        let destinationAbsent =
            !mutationTreeCopyPathExists(destination)

        let equivalent =
            observedInjectedFailure
            && unexpectedError == nil
            && sourceUnchanged
            && destinationAbsent

        print("filesystem mutation copy native fd walker rollback characterization")
        print("failure_injection: after_3_copied_entries")
        print("injected_failure_observed: \(observedInjectedFailure)")
        print("source_unchanged: \(sourceUnchanged)")
        print("destination_absent_after_rollback: \(destinationAbsent)")
        print("rollback_semantic_equivalent: \(equivalent)")
        if let unexpectedError {
            print("unexpected_error: \(unexpectedError)")
        }
        print("")

        return equivalent
    }

    static func mutationTreeCopyRunStrategyBenchmark(
        heavy: Bool,
        viable: Set<MutationTreeCopyCandidateLane>
    ) throws {
        let lanes = MutationTreeCopyCandidateLane.allCases.filter {
            viable.contains($0)
        }

        guard lanes.contains(.file_manager) else {
            throw TestFailure(message: "tree copy strategy benchmark has no FileManager oracle")
        }

        print("filesystem mutation copy directory-tree strategy benchmark")
        print("oracle: FileManager.default.copyItem")
        print("semantic_gate: success_and_failure_equivalent_only")
        print("setup_and_cleanup_timed: false")
        print("lane_paths: equal_length")
        print("lane_order: per_round_rotating_counterbalanced")
        print("heavy: \(heavy)")
        print("")

        let rounds = heavy ? 70 : 14
        let sampleCount = min(7, rounds)
        let baseRounds = rounds / sampleCount
        let extraRounds = rounds % sampleCount
        var samples: [MutationTreeCopyCandidateLane: [Double]] = [:]
        var laneIndices: [MutationTreeCopyCandidateLane: Int] = [:]

        for (index, lane) in MutationTreeCopyCandidateLane.allCases.enumerated() {
            laneIndices[lane] = index
        }

        for sampleIndex in 0..<sampleCount {
            let root = temporaryFileSystemRoot(
                prefix: "io-fs-copy-tree-benchmark-\(sampleIndex)"
            )
            let manager = FileManager.default
            let source = root.appendingPathComponent("source", isDirectory: true)
            let sampleRounds = baseRounds + (sampleIndex < extraRounds ? 1 : 0)

            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: root) }

            try mutationTreeCopyPrepareBenchmarkTree(
                source,
                branches: heavy ? 16 : 8,
                filesPerBranch: heavy ? 16 : 8
            )

            var sampleTotals: [MutationTreeCopyCandidateLane: Double] = [:]
            for lane in lanes {
                sampleTotals[lane] = 0
            }

            for roundIndex in 0..<sampleRounds {
                let order = mutationTreeCopyRotatedLanes(
                    lanes,
                    offset: sampleIndex + roundIndex
                )

                for lane in order {
                    guard let laneIndex = laneIndices[lane] else {
                        throw TestFailure(message: "tree copy benchmark lane index missing")
                    }

                    let destination = root.appendingPathComponent(
                        String(format: "destination-%02d", laneIndex),
                        isDirectory: true
                    )
                    try? manager.removeItem(at: destination)

                    let clock = ContinuousClock()
                    let started = clock.now
                    try mutationTreeCopyRunCandidate(
                        lane,
                        source: source,
                        destination: destination
                    )
                    sampleTotals[lane, default: 0] +=
                        mutationCopyDurationSeconds(started.duration(to: clock.now))

                    try manager.removeItem(at: destination)
                }
            }

            for lane in lanes {
                samples[lane, default: []].append(
                    sampleTotals[lane, default: 0] / Double(sampleRounds)
                )
            }
        }

        let fileManager = mutationCopyBenchmarkSummary(samples[.file_manager] ?? [])

        print("copy-mixed-tree")
        print("  branches: \(heavy ? 16 : 8)")
        print("  files_per_branch: \(heavy ? 16 : 8)")
        print("  rounds_per_lane: \(rounds)")
        print("  samples_per_lane: \(sampleCount)")

        for lane in lanes {
            let summary = mutationCopyBenchmarkSummary(samples[lane] ?? [])
            mutationCopyPrintTreeBenchmarkSummary(lane, summary: summary)

            if lane != .file_manager {
                print(
                    "  \(lane.rawValue)_vs_file_manager_x: "
                    + mutationCopyFormattedRatio(
                        fileManager.median / max(summary.median, .leastNonzeroMagnitude)
                    )
                )
            }
        }
        print("")
    }

    static func mutationTreeCopyRunCandidate(
        _ lane: MutationTreeCopyCandidateLane,
        source: URL,
        destination: URL
    ) throws {
        switch lane {
        case .file_manager:
            try FileManager.default.copyItem(at: source, to: destination)
        case .copyfile_recursive_clone:
            try mutationCopyCopyfile(
                source,
                destination: destination,
                flags: copyfile_flags_t(
                    COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE
                )
            )
        case .copyfile_recursive_all:
            try mutationCopyCopyfile(
                source,
                destination: destination,
                flags: copyfile_flags_t(
                    COPYFILE_ALL
                    | COPYFILE_RECURSIVE
                    | COPYFILE_EXCL
                    | COPYFILE_NOFOLLOW_SRC
                )
            )
        case .clonefile_directory:
            try mutationCopyClonefile(
                source,
                destination: destination,
                flags: UInt32(CLONE_ACL) | UInt32(CLONE_NOFOLLOW)
            )
        case .native_fd_walker:
            try FileSystem.c.copy(
                source,
                to: destination
            )
        }
    }

    static func mutationTreeCopyNativeFDWalker(
        source: URL,
        destination: URL,
        failureAfterCopiedEntries: Int? = nil
    ) throws {
        try source.withUnsafeFileSystemRepresentation {
            sourcePointer in

            guard let sourcePointer else {
                throw TestFailure(
                    message: "native fd walker could not borrow source filesystem representation"
                )
            }

            try destination.withUnsafeFileSystemRepresentation {
                destinationPointer in

                guard let destinationPointer else {
                    throw TestFailure(
                        message: "native fd walker could not borrow destination filesystem representation"
                    )
                }

                var destinationInfo = stat()
                if Darwin.lstat(
                    destinationPointer,
                    &destinationInfo
                ) == 0 {
                    throw TestFailure(
                        message: "native fd walker destination already exists"
                    )
                }

                let destinationProbeCode = errno
                guard destinationProbeCode == ENOENT else {
                    throw TestFailure(
                        message: "native fd walker destination preflight failed errno \(destinationProbeCode)"
                    )
                }

                let sourceDescriptor = Darwin.open(
                    sourcePointer,
                    O_RDONLY
                        | O_DIRECTORY
                        | O_CLOEXEC
                        | O_NOFOLLOW
                )

                guard sourceDescriptor >= 0 else {
                    let code = errno
                    throw TestFailure(
                        message: "native fd walker source open failed errno \(code)"
                    )
                }

                guard Darwin.mkdir(
                    destinationPointer,
                    mode_t(0o700)
                ) == 0 else {
                    let code = errno
                    _ = Darwin.close(sourceDescriptor)
                    throw TestFailure(
                        message: "native fd walker destination mkdir failed errno \(code)"
                    )
                }

                let destinationDescriptor = Darwin.open(
                    destinationPointer,
                    O_RDONLY
                        | O_DIRECTORY
                        | O_CLOEXEC
                        | O_NOFOLLOW
                )

                guard destinationDescriptor >= 0 else {
                    let code = errno
                    _ = Darwin.close(sourceDescriptor)
                    throw TestFailure(
                        message: "native fd walker destination open failed errno \(code)"
                    )
                }

                defer {
                    _ = Darwin.close(destinationDescriptor)
                }

                var failureState =
                    MutationTreeCopyNativeFailureState(
                        failAfterCopiedEntries:
                            failureAfterCopiedEntries
                    )

                do {
                    try mutationTreeCopyNativeFDWalkerDirectory(
                        sourceDescriptor: sourceDescriptor,
                        destinationDescriptor: destinationDescriptor,
                        failureState: &failureState
                    )
                } catch {
                    let copyError = error

                    do {
                        try FileSystem.c.remove(destination)
                    } catch {
                        throw TestFailure(
                            message:
                                "native fd walker rollback failed; "
                                + "copy_error=\(copyError); "
                                + "rollback_error=\(error)"
                        )
                    }

                    throw copyError
                }
            }
        }
    }

    /// Copies one already-open source directory into one already-open destination
    /// directory. Ownership of sourceDescriptor is consumed by fdopendir.
    /// destinationDescriptor remains owned by the caller.
    static func mutationTreeCopyNativeFDWalkerDirectory(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        failureState: inout MutationTreeCopyNativeFailureState
    ) throws {
        guard let directory = fdopendir(sourceDescriptor) else {
            let code = errno
            _ = Darwin.close(sourceDescriptor)
            throw TestFailure(
                message: "native fd walker fdopendir failed errno \(code)"
            )
        }

        defer {
            closedir(directory)
        }

        let sourceParentDescriptor = dirfd(directory)
        guard sourceParentDescriptor >= 0 else {
            let code = errno
            throw TestFailure(
                message: "native fd walker dirfd failed errno \(code)"
            )
        }

        while true {
            errno = 0

            guard let entry = readdir(directory) else {
                let code = errno
                guard code == 0 else {
                    throw TestFailure(
                        message: "native fd walker readdir failed errno \(code)"
                    )
                }
                break
            }

            try mutationTreeCopyWithDirectoryEntryNameCString(
                entry
            ) {
                name in

                if mutationTreeCopyIsDotDirectoryEntry(name) {
                    return
                }

                let entryType = Int32(
                    entry.pointee.d_type
                )

                if entryType == Int32(DT_DIR) {
                    try mutationTreeCopyNativeFDWalkerChildDirectory(
                        sourceParentDescriptor: sourceParentDescriptor,
                        destinationParentDescriptor: destinationDescriptor,
                        name: name,
                        failureState: &failureState
                    )
                    try failureState.recordCopiedEntry()
                    return
                }

                if entryType == Int32(DT_UNKNOWN) {
                    var entryInfo = stat()

                    guard Darwin.fstatat(
                        sourceParentDescriptor,
                        name,
                        &entryInfo,
                        AT_SYMLINK_NOFOLLOW
                    ) == 0 else {
                        let code = errno
                        throw TestFailure(
                            message: "native fd walker fstatat failed errno \(code)"
                        )
                    }

                    if entryInfo.st_mode
                        & mode_t(S_IFMT)
                        == mode_t(S_IFDIR)
                    {
                        try mutationTreeCopyNativeFDWalkerChildDirectory(
                            sourceParentDescriptor: sourceParentDescriptor,
                            destinationParentDescriptor: destinationDescriptor,
                            name: name,
                            failureState: &failureState
                        )
                        try failureState.recordCopiedEntry()
                        return
                    }
                }

                guard Darwin.clonefileat(
                    sourceParentDescriptor,
                    name,
                    destinationDescriptor,
                    name,
                    UInt32(CLONE_ACL)
                        | UInt32(CLONE_NOFOLLOW)
                ) == 0 else {
                    let code = errno
                    throw TestFailure(
                        message: "native fd walker clonefileat failed errno \(code)"
                    )
                }

                try failureState.recordCopiedEntry()
            }
        }

        try mutationTreeCopyNativeFinalizeDirectoryMetadata(
            sourceDescriptor: sourceParentDescriptor,
            destinationDescriptor: destinationDescriptor
        )
    }

    static func mutationTreeCopyNativeFDWalkerChildDirectory(
        sourceParentDescriptor: Int32,
        destinationParentDescriptor: Int32,
        name: UnsafePointer<CChar>,
        failureState: inout MutationTreeCopyNativeFailureState
    ) throws {
        guard Darwin.mkdirat(
            destinationParentDescriptor,
            name,
            mode_t(0o700)
        ) == 0 else {
            let code = errno
            throw TestFailure(
                message: "native fd walker child mkdirat failed errno \(code)"
            )
        }

        let sourceDescriptor = Darwin.openat(
            sourceParentDescriptor,
            name,
            O_RDONLY
                | O_DIRECTORY
                | O_CLOEXEC
                | O_NOFOLLOW
        )

        guard sourceDescriptor >= 0 else {
            let code = errno
            throw TestFailure(
                message: "native fd walker child source openat failed errno \(code)"
            )
        }

        let destinationDescriptor = Darwin.openat(
            destinationParentDescriptor,
            name,
            O_RDONLY
                | O_DIRECTORY
                | O_CLOEXEC
                | O_NOFOLLOW
        )

        guard destinationDescriptor >= 0 else {
            let code = errno
            _ = Darwin.close(sourceDescriptor)
            throw TestFailure(
                message: "native fd walker child destination openat failed errno \(code)"
            )
        }

        defer {
            _ = Darwin.close(destinationDescriptor)
        }

        try mutationTreeCopyNativeFDWalkerDirectory(
            sourceDescriptor: sourceDescriptor,
            destinationDescriptor: destinationDescriptor,
            failureState: &failureState
        )
    }

    /// Finalize directory metadata after all children have been created.
    ///
    /// M7c2 characterization established that FileManager preserves directory
    /// modification time but does not preserve directory creation/birth time.
    /// COPYFILE_METADATA matches that shape: apply it postorder so child
    /// insertion cannot disturb the preserved mtime, and deliberately do not
    /// repair birthtime.
    static func mutationTreeCopyNativeFinalizeDirectoryMetadata(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32
    ) throws {
        guard Darwin.fcopyfile(
            sourceDescriptor,
            destinationDescriptor,
            nil,
            copyfile_flags_t(COPYFILE_METADATA)
        ) == 0 else {
            let code = errno
            throw TestFailure(
                message: "native fd walker directory metadata finalization failed errno \(code)"
            )
        }
    }

    static func mutationTreeCopyPrintDirectoryPreservation(
        lane: MutationTreeCopyCandidateLane,
        observation: [MutationTreeCopySemanticEntry]
    ) {
        print("\(lane.rawValue)_directory_preservation:")

        for entry in observation
        where entry.kind == .directory
        {
            print(
                "  \(entry.relativePath)"
                + " mtime_preserved=\(entry.modificationPreserved)"
                + " creation_preserved=\(entry.creationPreserved)"
            )
        }
    }

    @inline(__always)
    static func mutationTreeCopyWithDirectoryEntryNameCString<Result>(
        _ pointer: UnsafeMutablePointer<dirent>,
        body: (UnsafePointer<CChar>) throws -> Result
    ) rethrows -> Result {
        let capacity = MemoryLayout.size(
            ofValue: pointer.pointee.d_name
        )

        return try withUnsafePointer(
            to: &pointer.pointee.d_name
        ) {
            nameStorage in

            try nameStorage.withMemoryRebound(
                to: CChar.self,
                capacity: capacity
            ) {
                try body($0)
            }
        }
    }

    @inline(__always)
    static func mutationTreeCopyIsDotDirectoryEntry(
        _ pointer: UnsafePointer<CChar>
    ) -> Bool {
        guard pointer[0] == CChar(46) else {
            return false
        }

        if pointer[1] == 0 {
            return true
        }

        return pointer[1] == CChar(46)
            && pointer[2] == 0
    }

    static func mutationTreeCopyPrepareRichTree(_ source: URL) throws {
        let manager = FileManager.default
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        let empty = source.appendingPathComponent("empty", isDirectory: true)
        let regular = source.appendingPathComponent("regular.bin")
        let nestedPayload = nested.appendingPathComponent("payload.bin")
        let hardA = source.appendingPathComponent("hard-a.bin")
        let hardB = source.appendingPathComponent("hard-b.bin")

        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try manager.createDirectory(at: empty, withIntermediateDirectories: false)
        try Data(
            repeating: 0x5a,
            count: 4096
        ).write(to: regular)
        try Data(
            repeating: 0xa5,
            count: 1537
        ).write(to: nestedPayload)
        try Data("hard-link-payload".utf8).write(to: hardA)
        try manager.linkItem(at: hardA, to: hardB)

        try manager.createSymbolicLink(
            atPath: source.appendingPathComponent("file-link").path,
            withDestinationPath: "regular.bin"
        )
        try manager.createSymbolicLink(
            atPath: source.appendingPathComponent("directory-link").path,
            withDestinationPath: "nested"
        )
        try manager.createSymbolicLink(
            atPath: source.appendingPathComponent("broken-link").path,
            withDestinationPath: "missing-target"
        )

        try mutationTreeCopyApplyMetadata(
            regular,
            mode: 0o640,
            modificationSeconds: 1_700_000_101,
            creationSeconds: 1_600_000_101,
            flags: UInt32(UF_HIDDEN),
            finderSeed: 0x31,
            comment: "tree-regular-comment",
            custom: "tree-regular-custom",
            acl: "everyone allow read"
        )
        try mutationTreeCopyApplyMetadata(
            nestedPayload,
            mode: 0o604,
            modificationSeconds: 1_700_000_202,
            creationSeconds: 1_600_000_202,
            flags: 0,
            finderSeed: 0x42,
            comment: "tree-nested-file-comment",
            custom: "tree-nested-file-custom",
            acl: nil
        )
        try mutationTreeCopyApplyMetadata(
            hardA,
            mode: 0o620,
            modificationSeconds: 1_700_000_303,
            creationSeconds: 1_600_000_303,
            flags: 0,
            finderSeed: 0x53,
            comment: "tree-hardlink-comment",
            custom: "tree-hardlink-custom",
            acl: nil
        )

        // Apply directory metadata after creating children so setup does not
        // overwrite the deliberately chosen directory timestamps.
        try mutationTreeCopyApplyMetadata(
            empty,
            mode: 0o700,
            modificationSeconds: 1_700_000_404,
            creationSeconds: 1_600_000_404,
            flags: 0,
            finderSeed: 0x64,
            comment: "tree-empty-comment",
            custom: "tree-empty-custom",
            acl: nil
        )
        try mutationTreeCopyApplyMetadata(
            nested,
            mode: 0o710,
            modificationSeconds: 1_700_000_505,
            creationSeconds: 1_600_000_505,
            flags: UInt32(UF_HIDDEN),
            finderSeed: 0x75,
            comment: "tree-nested-comment",
            custom: "tree-nested-custom",
            acl: "everyone allow read"
        )
        try mutationTreeCopyApplyMetadata(
            source,
            mode: 0o750,
            modificationSeconds: 1_700_000_606,
            creationSeconds: 1_600_000_606,
            flags: 0,
            finderSeed: 0x26,
            comment: "tree-root-comment",
            custom: "tree-root-custom",
            acl: "everyone allow read"
        )
    }

    static func mutationTreeCopyApplyMetadata(
        _ url: URL,
        mode: UInt16,
        modificationSeconds: TimeInterval,
        creationSeconds: TimeInterval,
        flags: UInt32,
        finderSeed: UInt8,
        comment: String,
        custom: String,
        acl: String?
    ) throws {
        try FileManager.default.setAttributes(
            [
                .posixPermissions: NSNumber(value: mode),
                .modificationDate: Date(timeIntervalSince1970: modificationSeconds),
                .creationDate: Date(timeIntervalSince1970: creationSeconds),
            ],
            ofItemAtPath: url.path
        )
        try mutationReplaceSetFlags(url, flags: flags)

        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo[0] = finderSeed
        finderInfo[9] = finderSeed ^ 0x5a
        finderInfo[31] = finderSeed ^ 0xa5

        let commentData = try PropertyListSerialization.data(
            fromPropertyList: comment,
            format: .binary,
            options: 0
        )

        try mutationReplaceSetXattr(
            url,
            name: mutationReplaceFinderInfoXattr,
            bytes: finderInfo
        )
        try mutationReplaceSetXattr(
            url,
            name: mutationReplaceSpotlightCommentXattr,
            bytes: Array(commentData)
        )
        try mutationReplaceSetXattr(
            url,
            name: mutationReplaceCustomXattr,
            bytes: Array(custom.utf8)
        )

        if let acl {
            try replaceACLAddEntry(acl, to: url)
        }
    }

    static func mutationTreeCopyPrepareFailureSource(_ source: URL) throws {
        let manager = FileManager.default
        let nested = source.appendingPathComponent("nested", isDirectory: true)

        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: source.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: nested.appendingPathComponent("b.txt"))
        try manager.createSymbolicLink(
            atPath: source.appendingPathComponent("link").path,
            withDestinationPath: "a.txt"
        )
    }

    static func mutationTreeCopyPrepareBenchmarkTree(
        _ root: URL,
        branches: Int,
        filesPerBranch: Int
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        for branch in 0..<branches {
            let branchURL = root.appendingPathComponent(
                "branch-\(branch)",
                isDirectory: true
            )
            try manager.createDirectory(at: branchURL, withIntermediateDirectories: false)

            for fileIndex in 0..<filesPerBranch {
                let byteCount = 512 + ((branch + fileIndex) % 8) * 127
                try Data(
                    repeating: UInt8(truncatingIfNeeded: branch &* 17 &+ fileIndex),
                    count: byteCount
                ).write(
                    to: branchURL.appendingPathComponent("file-\(fileIndex).bin")
                )
            }

            let leaf = branchURL.appendingPathComponent("leaf", isDirectory: true)
            try manager.createDirectory(at: leaf, withIntermediateDirectories: false)
            try Data(
                repeating: UInt8(truncatingIfNeeded: branch),
                count: 1024
            ).write(
                to: leaf.appendingPathComponent("payload.bin")
            )
        }
    }

    static func mutationTreeCopySemanticObservation(
        source: URL,
        destination: URL
    ) throws -> [MutationTreeCopySemanticEntry] {
        let sourceObservation = try mutationTreeCopyObservation(source)
        let destinationObservation = try mutationTreeCopyObservation(destination)
        let sourceByPath = Dictionary(
            uniqueKeysWithValues: sourceObservation.map {
                ($0.relativePath, $0)
            }
        )

        return destinationObservation.map { destinationEntry in
            let sourceEntry = sourceByPath[destinationEntry.relativePath]

            return .init(
                relativePath: destinationEntry.relativePath,
                kind: destinationEntry.kind,
                mode: destinationEntry.mode,
                modificationPreserved:
                    sourceEntry?.modificationSeconds
                        == destinationEntry.modificationSeconds,
                creationPreserved:
                    sourceEntry?.creationSeconds
                        == destinationEntry.creationSeconds,
                flags: destinationEntry.flags,
                finderInfo: destinationEntry.finderInfo,
                spotlightComment: destinationEntry.spotlightComment,
                customXattr: destinationEntry.customXattr,
                acl: destinationEntry.acl,
                bytes: destinationEntry.bytes,
                symbolicLinkTarget: destinationEntry.symbolicLinkTarget,
                hardLinkGroup: destinationEntry.hardLinkGroup
            )
        }
    }

    static func mutationTreeCopyObservation(
        _ root: URL
    ) throws -> [MutationTreeCopyEntryObservation] {
        var result: [MutationTreeCopyEntryObservation] = []
        var hardLinkGroups: [String: Int] = [:]
        var nextHardLinkGroup = 0

        try mutationTreeCopyAppendObservation(
            root,
            relativePath: ".",
            result: &result,
            hardLinkGroups: &hardLinkGroups,
            nextHardLinkGroup: &nextHardLinkGroup
        )
        return result
    }

    static func mutationTreeCopyAppendObservation(
        _ url: URL,
        relativePath: String,
        result: inout [MutationTreeCopyEntryObservation],
        hardLinkGroups: inout [String: Int],
        nextHardLinkGroup: inout Int
    ) throws {
        let info = try mutationTreeCopyLstat(url)
        let kind = mutationTreeCopyEntryKind(info)
        let metadata: MutationReplaceMetadataObservation?
        if kind == .regular_file || kind == .directory {
            metadata = try mutationReplaceMetadataObservation(url)
        } else {
            metadata = nil
        }

        let hardLinkGroup: Int?
        if kind == .regular_file, info.st_nlink > 1 {
            let identity = "\(info.st_dev):\(info.st_ino)"
            if let existing = hardLinkGroups[identity] {
                hardLinkGroup = existing
            } else {
                hardLinkGroup = nextHardLinkGroup
                hardLinkGroups[identity] = nextHardLinkGroup
                nextHardLinkGroup += 1
            }
        } else {
            hardLinkGroup = nil
        }

        let acl: String?
        if kind == .regular_file || kind == .directory {
            acl = try replaceACLText(url)
        } else {
            acl = nil
        }

        let bytes: [UInt8]?
        if kind == .regular_file {
            bytes = Array(try Data(contentsOf: url))
        } else {
            bytes = nil
        }

        let symbolicLinkTarget: String?
        if kind == .symbolic_link {
            symbolicLinkTarget =
                try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        } else {
            symbolicLinkTarget = nil
        }

        result.append(
            .init(
                relativePath: relativePath,
                kind: kind,
                mode: UInt32(info.st_mode & mode_t(0o7777)),
                modificationSeconds: Int64(info.st_mtimespec.tv_sec),
                creationSeconds: Int64(info.st_birthtimespec.tv_sec),
                flags: UInt32(info.st_flags),
                finderInfo: metadata?.finderInfo,
                spotlightComment: metadata?.spotlightComment,
                customXattr: metadata?.customXattr,
                acl: acl,
                bytes: bytes,
                symbolicLinkTarget: symbolicLinkTarget,
                hardLinkGroup: hardLinkGroup
            )
        )

        guard kind == .directory else {
            return
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }

        for child in children {
            let childRelativePath =
                relativePath == "."
                ? child.lastPathComponent
                : relativePath + "/" + child.lastPathComponent

            try mutationTreeCopyAppendObservation(
                child,
                relativePath: childRelativePath,
                result: &result,
                hardLinkGroups: &hardLinkGroups,
                nextHardLinkGroup: &nextHardLinkGroup
            )
        }
    }

    static func mutationTreeCopyNamespaceObservation(
        _ root: URL
    ) throws -> [MutationTreeCopyNamespaceEntry] {
        var result: [MutationTreeCopyNamespaceEntry] = []
        try mutationTreeCopyAppendNamespaceObservation(
            root,
            relativePath: ".",
            result: &result
        )
        return result
    }

    static func mutationTreeCopyAppendNamespaceObservation(
        _ url: URL,
        relativePath: String,
        result: inout [MutationTreeCopyNamespaceEntry]
    ) throws {
        let info = try mutationTreeCopyLstat(url)
        let kind = mutationTreeCopyEntryKind(info)

        let bytes: [UInt8]?
        if kind == .regular_file {
            bytes = Array(try Data(contentsOf: url))
        } else {
            bytes = nil
        }

        let symbolicLinkTarget: String?
        if kind == .symbolic_link {
            symbolicLinkTarget =
                try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        } else {
            symbolicLinkTarget = nil
        }

        result.append(
            .init(
                relativePath: relativePath,
                kind: kind,
                bytes: bytes,
                symbolicLinkTarget: symbolicLinkTarget
            )
        )

        guard kind == .directory else {
            return
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }

        for child in children {
            let childRelativePath =
                relativePath == "."
                ? child.lastPathComponent
                : relativePath + "/" + child.lastPathComponent

            try mutationTreeCopyAppendNamespaceObservation(
                child,
                relativePath: childRelativePath,
                result: &result
            )
        }
    }

    static func mutationTreeCopyPathExists(_ url: URL) -> Bool {
        var info = stat()

        return url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else {
                return false
            }
            return Darwin.lstat(pointer, &info) == 0
        }
    }

    static func mutationTreeCopyLstat(_ url: URL) throws -> stat {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else {
                return Int32(-1)
            }
            return Darwin.lstat(pointer, &info)
        }

        guard result == 0 else {
            throw TestFailure(
                message: "tree copy lstat failed errno \(errno) for \(url.path)"
            )
        }
        return info
    }

    static func mutationTreeCopyEntryKind(_ info: stat) -> MutationTreeCopyEntryKind {
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR):
            return .directory
        case mode_t(S_IFREG):
            return .regular_file
        case mode_t(S_IFLNK):
            return .symbolic_link
        default:
            return .other
        }
    }

    static func mutationTreeCopyStructureMatches(
        _ candidate: [MutationTreeCopySemanticEntry],
        _ oracle: [MutationTreeCopySemanticEntry]
    ) -> Bool {
        guard candidate.count == oracle.count else {
            return false
        }
        return zip(candidate, oracle).allSatisfy { pair in
            pair.0.relativePath == pair.1.relativePath
                && pair.0.kind == pair.1.kind
        }
    }

    static func mutationTreeCopyMetadataMatches(
        _ candidate: [MutationTreeCopySemanticEntry],
        _ oracle: [MutationTreeCopySemanticEntry]
    ) -> Bool {
        guard mutationTreeCopyStructureMatches(candidate, oracle) else {
            return false
        }

        return zip(candidate, oracle).allSatisfy { pair in
            pair.0.mode == pair.1.mode
                && pair.0.modificationPreserved == pair.1.modificationPreserved
                && pair.0.creationPreserved == pair.1.creationPreserved
                && pair.0.flags == pair.1.flags
                && pair.0.finderInfo == pair.1.finderInfo
                && pair.0.spotlightComment == pair.1.spotlightComment
                && pair.0.customXattr == pair.1.customXattr
                && pair.0.acl == pair.1.acl
        }
    }

    static func mutationTreeCopyPayloadMatches(
        _ candidate: [MutationTreeCopySemanticEntry],
        _ oracle: [MutationTreeCopySemanticEntry]
    ) -> Bool {
        guard mutationTreeCopyStructureMatches(candidate, oracle) else {
            return false
        }

        return zip(candidate, oracle).allSatisfy { pair in
            pair.0.bytes == pair.1.bytes
                && pair.0.symbolicLinkTarget == pair.1.symbolicLinkTarget
        }
    }

    static func mutationTreeCopyHardLinkMatches(
        _ candidate: [MutationTreeCopySemanticEntry],
        _ oracle: [MutationTreeCopySemanticEntry]
    ) -> Bool {
        guard mutationTreeCopyStructureMatches(candidate, oracle) else {
            return false
        }

        return zip(candidate, oracle).allSatisfy { pair in
            pair.0.hardLinkGroup == pair.1.hardLinkGroup
        }
    }

    static func mutationTreeCopyFirstDifference(
        _ candidate: [MutationTreeCopySemanticEntry],
        _ oracle: [MutationTreeCopySemanticEntry]
    ) -> String? {
        guard candidate.count == oracle.count else {
            return "entry_count candidate=\(candidate.count) oracle=\(oracle.count)"
        }

        for (candidateEntry, oracleEntry) in zip(candidate, oracle) {
            if candidateEntry.relativePath != oracleEntry.relativePath {
                return "path candidate=\(candidateEntry.relativePath) oracle=\(oracleEntry.relativePath)"
            }

            let path = oracleEntry.relativePath
            if candidateEntry.kind != oracleEntry.kind { return "\(path) kind" }
            if candidateEntry.mode != oracleEntry.mode { return "\(path) mode" }
            if candidateEntry.modificationPreserved != oracleEntry.modificationPreserved { return "\(path) mtime_preserved" }
            if candidateEntry.creationPreserved != oracleEntry.creationPreserved { return "\(path) creation_time_preserved" }
            if candidateEntry.flags != oracleEntry.flags { return "\(path) bsd_flags" }
            if candidateEntry.finderInfo != oracleEntry.finderInfo { return "\(path) FinderInfo" }
            if candidateEntry.spotlightComment != oracleEntry.spotlightComment { return "\(path) Finder_comment" }
            if candidateEntry.customXattr != oracleEntry.customXattr { return "\(path) custom_xattr" }
            if candidateEntry.acl != oracleEntry.acl { return "\(path) ACL" }
            if candidateEntry.bytes != oracleEntry.bytes { return "\(path) bytes" }
            if candidateEntry.symbolicLinkTarget != oracleEntry.symbolicLinkTarget { return "\(path) symlink_target" }
            if candidateEntry.hardLinkGroup != oracleEntry.hardLinkGroup { return "\(path) hard_link_topology" }
        }

        return nil
    }

    static func mutationTreeCopyRotatedLanes(
        _ lanes: [MutationTreeCopyCandidateLane],
        offset: Int
    ) -> [MutationTreeCopyCandidateLane] {
        guard !lanes.isEmpty else {
            return []
        }
        let normalized = offset % lanes.count
        return Array(lanes[normalized...]) + Array(lanes[..<normalized])
    }

    static func mutationCopyPrintTreeBenchmarkSummary(
        _ lane: MutationTreeCopyCandidateLane,
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
}
#endif
