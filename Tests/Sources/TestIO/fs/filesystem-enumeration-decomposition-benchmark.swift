import Foundation
import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    static func runFileSystemEnumerationDecompositionBenchmarks(
        heavy: Bool
    ) throws {
        try withFileSystemBenchmarkFixture(
            heavy: heavy
        ) { fixture in
            let directory =
                fixture.flatWide10K
                ?? fixture.flatWide1K
            let expectedEntries = try FileSystem.foundation
                .directory
                .entries(
                    directory
                )
                .count
            let rounds = heavy ? 20 : 20

            print("")
            print("filesystem native enumeration decomposition")
            print(
                "directory_entries: \(expectedEntries)"
            )
            print("rounds: \(rounds)")
            print("")

            let stages: [
                (
                    name: String,
                    operation: () throws -> Int
                )
            ] = [
                (
                    "raw-readdir",
                    {
                        try rawDirectoryEntryCount(
                            directory
                        )
                    }
                ),
                (
                    "name-materialization",
                    {
                        try materializedDirectoryNames(
                            directory
                        )
                    }
                ),
                (
                    "native-path-owned-full-bytes",
                    {
                        try materializedOwnedNativePaths(
                            directory
                        )
                    }
                ),
                (
                    "native-path-shared-storage",
                    {
                        try materializedSharedNativePaths(
                            directory
                        )
                    }
                ),
                (
                    "native-path-substrate-shared-storage",
                    {
                        try materializedNativePathSubstrate(
                            directory
                        )
                    }
                ),
                (
                    "url-materialization-check-filesystem",
                    {
                        try materializedDirectoryURLs(
                            directory
                        )
                    }
                ),
                (
                    "url-materialization-known-kind",
                    {
                        try materializedHintedDirectoryURLs(
                            directory
                        )
                    }
                ),
                (
                    "entry-materialization",
                    {
                        try materializedDirectoryEntries(
                            directory
                        )
                    }
                ),
                (
                    "trusted-entry-materialization-check-filesystem",
                    {
                        try materializedTrustedDirectoryEntries(
                            directory
                        )
                    }
                ),
                (
                    "trusted-entry-materialization-known-kind",
                    {
                        try materializedHintedTrustedDirectoryEntries(
                            directory
                        )
                    }
                ),
                (
                    "c-public-api",
                    {
                        try FileSystem.c
                            .directory
                            .entries(
                                directory
                            )
                            .count
                    }
                ),
            ]

            var rawSeconds: Double?

            for stage in stages {
                let measurement = try measureEnumerationStage(
                    rounds: rounds,
                    operation: stage.operation
                )

                try expectEqual(
                    measurement.entries,
                    expectedEntries * rounds,
                    "enumeration decomposition count for \(stage.name)"
                )

                if rawSeconds == nil {
                    rawSeconds = measurement.wallSeconds
                }

                print(stage.name)
                print(
                    "  wall_seconds: "
                        + formattedEnumerationSeconds(
                            measurement.wallSeconds
                        )
                )
                print(
                    "  entries_observed: "
                        + "\(measurement.entries)"
                )
                print(
                    "  nanoseconds_per_entry: "
                        + String(
                            format: "%.1f",
                            measurement.wallSeconds
                                * 1_000_000_000
                                / Double(measurement.entries)
                        )
                )

                if let rawSeconds {
                    print(
                        "  relative_to_raw_x: "
                            + String(
                                format: "%.3f",
                                measurement.wallSeconds
                                    / rawSeconds
                            )
                    )
                }

                print("")
            }

            let nativePathMetrics = try nativePathPrototypeMetrics(
                directory
            )
            print("native-path prototype logical storage")
            print("  parent_bytes: \(nativePathMetrics.parentBytes)")
            print("  child_name_bytes: \(nativePathMetrics.childNameBytes)")
            print("  entries: \(nativePathMetrics.entries)")
            print(
                "  owned_logical_bytes: "
                    + "\(nativePathMetrics.ownedLogicalBytes)"
            )
            print(
                "  shared_logical_bytes: "
                    + "\(nativePathMetrics.sharedLogicalBytes)"
            )
            print(
                "  owned_to_shared_logical_bytes_x: "
                    + String(
                        format: "%.3f",
                        Double(nativePathMetrics.ownedLogicalBytes)
                            / Double(nativePathMetrics.sharedLogicalBytes)
                    )
            )
            print("")
        }
    }
}

private extension TestIO {
    struct EnumerationStageMeasurement {
        let wallSeconds: Double
        let entries: Int
    }

    struct BenchmarkOwnedNativePath {
        let bytes: [UInt8]
        let kind: FileKind
    }

    struct BenchmarkSharedNativePathEntry {
        let nameRange: Range<Int>
        let kind: FileKind
    }

    struct BenchmarkSharedNativePathBatch {
        let parent: [UInt8]
        let names: [UInt8]
        let entries: [BenchmarkSharedNativePathEntry]
    }

    struct BenchmarkNativePathMetrics {
        let parentBytes: Int
        let childNameBytes: Int
        let entries: Int
        let ownedLogicalBytes: Int
        let sharedLogicalBytes: Int
    }

    static func measureEnumerationStage(
        rounds: Int,
        operation: () throws -> Int
    ) throws -> EnumerationStageMeasurement {
        let clock = ContinuousClock()
        let started = clock.now
        var entries = 0

        for _ in 0..<rounds {
            entries += try operation()
        }

        return .init(
            wallSeconds: enumerationSeconds(
                started.duration(
                    to: clock.now
                )
            ),
            entries: entries
        )
    }

    static func rawDirectoryEntryCount(
        _ url: URL
    ) throws -> Int {
        var count = 0

        try forEachRawDirectoryEntry(
            url
        ) { _ in
            count += 1
        }

        return count
    }

    static func materializedDirectoryNames(
        _ url: URL
    ) throws -> Int {
        var names: [String] = []

        try forEachRawDirectoryEntry(
            url
        ) { pointer in
            names.append(
                benchmarkDirectoryEntryName(
                    pointer
                )
            )
        }

        retainEnumerationValue(
            names
        )
        return names.count
    }

    static func materializedOwnedNativePaths(
        _ url: URL
    ) throws -> Int {
        let parent = benchmarkFileSystemPathBytes(url)
        let needsSeparator = parent.last != 47
        var entries: [BenchmarkOwnedNativePath] = []

        try forEachRawDirectoryEntry(
            url
        ) { pointer in
            let kind = benchmarkFileKind(
                directoryEntryType: Int32(
                    pointer.pointee.d_type
                )
            )

            withBenchmarkDirectoryEntryNameBytes(
                pointer
            ) { nameBytes in
                var bytes: [UInt8] = []
                bytes.reserveCapacity(
                    parent.count
                        + (needsSeparator ? 1 : 0)
                        + nameBytes.count
                )
                bytes.append(contentsOf: parent)
                if needsSeparator {
                    bytes.append(47)
                }
                bytes.append(contentsOf: nameBytes)

                entries.append(
                    .init(
                        bytes: bytes,
                        kind: kind
                    )
                )
            }
        }

        retainEnumerationValue(entries)
        return entries.count
    }

    static func materializedSharedNativePaths(
        _ url: URL
    ) throws -> Int {
        let parent = benchmarkFileSystemPathBytes(url)
        var names: [UInt8] = []
        var entries: [BenchmarkSharedNativePathEntry] = []

        try forEachRawDirectoryEntry(
            url
        ) { pointer in
            let kind = benchmarkFileKind(
                directoryEntryType: Int32(
                    pointer.pointee.d_type
                )
            )
            let start = names.count

            withBenchmarkDirectoryEntryNameBytes(
                pointer
            ) { nameBytes in
                names.append(contentsOf: nameBytes)
            }

            entries.append(
                .init(
                    nameRange: start..<names.count,
                    kind: kind
                )
            )
        }

        let batch = BenchmarkSharedNativePathBatch(
            parent: parent,
            names: names,
            entries: entries
        )
        retainEnumerationValue(batch)
        return batch.entries.count
    }

    static func nativePathPrototypeMetrics(
        _ url: URL
    ) throws -> BenchmarkNativePathMetrics {
        let parent = benchmarkFileSystemPathBytes(url)
        let separatorBytes = parent.last == 47 ? 0 : 1
        var childNameBytes = 0
        var entries = 0
        var ownedPathBytes = 0

        try forEachRawDirectoryEntry(
            url
        ) { pointer in
            withBenchmarkDirectoryEntryNameBytes(
                pointer
            ) { nameBytes in
                childNameBytes += nameBytes.count
                ownedPathBytes += parent.count
                    + separatorBytes
                    + nameBytes.count
                entries += 1
            }
        }

        let ownedLogicalBytes = ownedPathBytes
            + entries * MemoryLayout<BenchmarkOwnedNativePath>.stride
        let sharedLogicalBytes = parent.count
            + childNameBytes
            + entries
                * MemoryLayout<BenchmarkSharedNativePathEntry>.stride

        return .init(
            parentBytes: parent.count,
            childNameBytes: childNameBytes,
            entries: entries,
            ownedLogicalBytes: ownedLogicalBytes,
            sharedLogicalBytes: sharedLogicalBytes
        )
    }

    static func materializedNativePathSubstrate(
        _ url: URL
    ) throws -> Int {
        guard let parent = NativePath(
            fileSystemURL: url
        ) else {
            throw TestFailure(
                message: "benchmark directory could not form NativePath"
            )
        }

        var builder = NativeDirectoryEntries.Builder(
            parent: parent
        )

        try forEachRawDirectoryEntry(
            url
        ) { pointer in
            let kind = benchmarkFileKind(
                directoryEntryType: Int32(
                    pointer.pointee.d_type
                )
            )

            withBenchmarkDirectoryEntryNameBytes(
                pointer
            ) {
                builder.appendTrustedFileSystemComponent(
                    $0,
                    kind: kind,
                    isDirectoryPath:
                        kind == .directory
                )
            }
        }

        let entries = builder.build()
        retainEnumerationValue(
            entries
        )
        return entries.count
    }

    static func materializedDirectoryURLs(
        _ url: URL
    ) throws -> Int {
        var urls: [URL] = []

        try forEachRawDirectoryEntry(
            url
        ) { pointer in
            urls.append(
                url.appending(
                    component: benchmarkDirectoryEntryName(
                        pointer
                    ),
                    directoryHint: .checkFileSystem
                )
            )
        }

        retainEnumerationValue(
            urls
        )
        return urls.count
    }

    static func materializedHintedDirectoryURLs(
        _ url: URL
    ) throws -> Int {
        var urls: [URL] = []

        try forEachRawDirectoryEntry(
            url
        ) { pointer in
            let kind = benchmarkFileKind(
                directoryEntryType: Int32(
                    pointer.pointee.d_type
                )
            )

            urls.append(
                url.appending(
                    component: benchmarkDirectoryEntryName(
                        pointer
                    ),
                    directoryHint: benchmarkDirectoryHint(
                        for: kind
                    )
                )
            )
        }

        retainEnumerationValue(
            urls
        )
        return urls.count
    }

    static func materializedDirectoryEntries(
        _ url: URL
    ) throws -> Int {
        var entries: [FileSystemEntry] = []

        try forEachRawDirectoryEntry(
            url
        ) { pointer in
            let child = url.appending(
                component: benchmarkDirectoryEntryName(
                    pointer
                ),
                directoryHint: .checkFileSystem
            )

            entries.append(
                .init(
                    url: child,
                    kind: benchmarkFileKind(
                        directoryEntryType:
                            Int32(
                                pointer.pointee.d_type
                            )
                    )
                )
            )
        }

        retainEnumerationValue(
            entries
        )
        return entries.count
    }

    static func materializedTrustedDirectoryEntries(
        _ url: URL
    ) throws -> Int {
        var entries: [FileSystemEntry] = []

        try forEachRawDirectoryEntry(
            url
        ) { pointer in
            let child = url.appending(
                component: benchmarkDirectoryEntryName(
                    pointer
                ),
                directoryHint: .checkFileSystem
            )

            entries.append(
                .init(
                    standardizedURL: child,
                    kind: benchmarkFileKind(
                        directoryEntryType:
                            Int32(
                                pointer.pointee.d_type
                            )
                    )
                )
            )
        }

        retainEnumerationValue(
            entries
        )
        return entries.count
    }

    static func materializedHintedTrustedDirectoryEntries(
        _ url: URL
    ) throws -> Int {
        var entries: [FileSystemEntry] = []

        try forEachRawDirectoryEntry(
            url
        ) { pointer in
            let kind = benchmarkFileKind(
                directoryEntryType: Int32(
                    pointer.pointee.d_type
                )
            )
            let child = url.appending(
                component: benchmarkDirectoryEntryName(
                    pointer
                ),
                directoryHint: benchmarkDirectoryHint(
                    for: kind
                )
            )

            entries.append(
                .init(
                    standardizedURL: child,
                    kind: kind
                )
            )
        }

        retainEnumerationValue(
            entries
        )
        return entries.count
    }

    static func forEachRawDirectoryEntry(
        _ input: URL,
        body: (UnsafeMutablePointer<dirent>) throws -> Void
    ) throws {
        let url = input.standardizedFileURL

        guard let directory = url.path.withCString({
            opendir($0)
        }) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [
                    NSFilePathErrorKey: url.path,
                ]
            )
        }

        defer {
            closedir(directory)
        }

        while true {
            errno = 0

            guard let pointer = readdir(directory) else {
                let code = errno

                if code != 0 {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(code),
                        userInfo: [
                            NSFilePathErrorKey: url.path,
                        ]
                    )
                }

                return
            }

            if benchmarkDirectoryEntryIsDot(
                pointer
            ) {
                continue
            }

            try body(
                pointer
            )
        }
    }

    static func benchmarkDirectoryEntryIsDot(
        _ pointer: UnsafeMutablePointer<dirent>
    ) -> Bool {
        let capacity = MemoryLayout.size(
            ofValue: pointer.pointee.d_name
        )

        return withUnsafePointer(
            to: &pointer.pointee.d_name
        ) {
            $0.withMemoryRebound(
                to: CChar.self,
                capacity: capacity
            ) {
                guard $0[0] == 46 else {
                    return false
                }

                if $0[1] == 0 {
                    return true
                }

                return $0[1] == 46
                    && $0[2] == 0
            }
        }
    }

    static func benchmarkDirectoryEntryName(
        _ pointer: UnsafeMutablePointer<dirent>
    ) -> String {
        let capacity = MemoryLayout.size(
            ofValue: pointer.pointee.d_name
        )

        #if canImport(Darwin)
        let length = Int(
            pointer.pointee.d_namlen
        )

        return withUnsafePointer(
            to: &pointer.pointee.d_name
        ) {
            $0.withMemoryRebound(
                to: UInt8.self,
                capacity: capacity
            ) {
                String(
                    decoding: UnsafeBufferPointer(
                        start: $0,
                        count: length
                    ),
                    as: UTF8.self
                )
            }
        }
        #else
        return withUnsafePointer(
            to: &pointer.pointee.d_name
        ) {
            $0.withMemoryRebound(
                to: CChar.self,
                capacity: capacity
            ) {
                String(cString: $0)
            }
        }
        #endif
    }

    static func benchmarkFileSystemPathBytes(
        _ url: URL
    ) -> [UInt8] {
        url.standardizedFileURL.withUnsafeFileSystemRepresentation {
            pointer in
            guard let pointer else {
                return []
            }

            let count = Int(strlen(pointer))
            return pointer.withMemoryRebound(
                to: UInt8.self,
                capacity: max(count, 1)
            ) { bytes in
                Array(
                    UnsafeBufferPointer(
                        start: bytes,
                        count: count
                    )
                )
            }
        }
    }

    static func withBenchmarkDirectoryEntryNameBytes<Result>(
        _ pointer: UnsafeMutablePointer<dirent>,
        body: (UnsafeBufferPointer<UInt8>) -> Result
    ) -> Result {
        let capacity = MemoryLayout.size(
            ofValue: pointer.pointee.d_name
        )

        return withUnsafePointer(
            to: &pointer.pointee.d_name
        ) {
            $0.withMemoryRebound(
                to: UInt8.self,
                capacity: capacity
            ) { bytes in
                #if canImport(Darwin)
                let length = Int(pointer.pointee.d_namlen)
                #else
                var length = 0
                while length < capacity && bytes[length] != 0 {
                    length += 1
                }
                #endif

                return body(
                    UnsafeBufferPointer(
                        start: bytes,
                        count: length
                    )
                )
            }
        }
    }

    static func benchmarkFileKind(
        directoryEntryType: Int32
    ) -> FileKind {
        switch directoryEntryType {
        case Int32(DT_REG):
            return .file
        case Int32(DT_DIR):
            return .directory
        case Int32(DT_LNK):
            return .symlink
        default:
            return .other
        }
    }

    static func benchmarkDirectoryHint(
        for kind: FileKind
    ) -> URL.DirectoryHint {
        switch kind {
        case .directory:
            return .isDirectory
        case .symlink:
            return .checkFileSystem
        case .file, .other:
            return .notDirectory
        }
    }

    @inline(never)
    static func retainEnumerationValue<Value>(
        _ value: Value
    ) {
        withExtendedLifetime(
            value
        ) {}
    }

    static func formattedEnumerationSeconds(
        _ value: Double
    ) -> String {
        String(
            format: "%.6f",
            value
        )
    }

    static func enumerationSeconds(
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
