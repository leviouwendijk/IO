import Foundation
import IO

extension TestIO {
    static func testFileSystemDirectEntryKinds() throws {
        try withFileSystemFixture { fixture in
            let entries = try FileSystem.default.directory.entries(
                fixture.root
            )

            let kinds = Dictionary(
                uniqueKeysWithValues: entries.map {
                    (
                        $0.url.lastPathComponent,
                        $0.kind
                    )
                }
            )

            try expectEqual(
                kinds["regular.txt"],
                .file,
                "regular file kind"
            )
            try expectEqual(
                kinds["empty"],
                .directory,
                "empty directory kind"
            )
            try expectEqual(
                kinds["nested"],
                .directory,
                "nested directory kind"
            )
            try expectEqual(
                kinds["file-link"],
                .symlink,
                "file symlink kind"
            )
            try expectEqual(
                kinds["directory-link"],
                .symlink,
                "directory symlink kind"
            )
            try expectEqual(
                kinds["broken-link"],
                .symlink,
                "broken symlink kind"
            )
            try expectEqual(
                kinds["fifo"],
                .other,
                "fifo kind"
            )

            try expect(
                !entries.contains {
                    $0.url == fixture.nestedFile
                },
                "direct enumeration must not include nested children"
            )
        }
    }

    static func testFileSystemRecursiveWideAndDeep() throws {
        try withFileSystemFixture(
            wideCount: 96,
            deepDepth: 12
        ) { fixture in
            let fileSystem = FileSystem.default

            let wideEntries = try fileSystem.directory.entries(
                fixture.wideDirectory
            )

            try expectEqual(
                wideEntries.count,
                96,
                "wide direct entry count"
            )

            let deepEntries = try fileSystem.directory.entries(
                fixture.deepRoot,
                recursive: true
            )

            try expectEqual(
                deepEntries.count,
                24,
                "deep recursive entry count"
            )

            try expect(
                deepEntries.contains {
                    $0.url == fixture.deepestDirectory
                        && $0.kind == .directory
                },
                "deep recursive enumeration must reach deepest directory"
            )
        }
    }

    static func testFileInspectorSemantics() throws {
        try withFileSystemFixture { fixture in
            let regular = try FileInspector(
                fixture.regularFile
            ).inspect()

            try expect(
                regular.existed,
                "regular file must exist"
            )
            try expectEqual(
                regular.kind,
                .file,
                "regular inspector kind"
            )
            try expectEqual(
                regular.byteCount,
                5,
                "regular inspector byte count"
            )
            try expect(
                regular.modifiedAt != nil,
                "regular inspector modified date"
            )
            try expect(
                regular.identity != nil,
                "regular inspector identity"
            )

            let directory = try FileInspector(
                fixture.emptyDirectory
            ).inspect()

            try expect(
                directory.existed,
                "directory must exist"
            )
            try expectEqual(
                directory.kind,
                .directory,
                "directory inspector kind"
            )

            let symlink = try FileInspector(
                fixture.fileSymlink
            ).inspect()

            try expect(
                symlink.existed,
                "symlink must exist"
            )
            try expectEqual(
                symlink.kind,
                .symlink,
                "symlink inspector kind"
            )

            let other = try FileInspector(
                fixture.fifo
            ).inspect()

            try expect(
                other.existed,
                "fifo must exist"
            )
            try expectEqual(
                other.kind,
                .other,
                "fifo inspector kind"
            )

            let missing = try FileInspector(
                fixture.missing
            ).inspect()

            try expect(
                !missing.existed,
                "missing path must be represented as non-existent"
            )
            try expectEqual(
                missing.byteCount,
                nil,
                "missing byte count"
            )
            try expectEqual(
                missing.modifiedAt,
                nil,
                "missing modified date"
            )
            try expectEqual(
                missing.identity,
                nil,
                "missing identity"
            )
            try expectEqual(
                missing.kind,
                nil,
                "missing kind"
            )
        }
    }

    static func testDirectoryInspectorSemantics() throws {
        try withFileSystemFixture { fixture in
            let empty = try DirectoryInspector(
                fixture.emptyDirectory
            ).isEmpty()

            try expect(
                empty,
                "empty directory probe"
            )

            let nestedIsEmpty = try DirectoryInspector(
                fixture.nestedDirectory
            ).isEmpty()

            try expect(
                !nestedIsEmpty,
                "non-empty directory probe"
            )

            let snapshots = try DirectoryInspector(
                fixture.nestedDirectory
            ).entries()

            try expectEqual(
                snapshots.count,
                1,
                "directory inspector entry count"
            )
            try expectEqual(
                snapshots[0].url,
                fixture.nestedFile.standardizedFileURL,
                "directory inspector child"
            )
            try expectEqual(
                snapshots[0].kind,
                .file,
                "directory inspector child kind"
            )
        }
    }

    static func testFileSystemMissingAndErrorShape() throws {
        try withFileSystemFixture { fixture in
            let fileSystem = FileSystem.default

            try expect(
                fileSystem.exists(
                    fixture.regularFile
                ),
                "exists regular file"
            )
            try expect(
                !fileSystem.exists(
                    fixture.missing
                ),
                "missing path must not exist"
            )

            try expectEqual(
                fileSystem.resolve(
                    fixture.fileSymlink
                ),
                fixture.regularFile.standardizedFileURL,
                "symlink resolution"
            )

            var missingEnumerationThrew = false

            do {
                _ = try fileSystem.directory.entries(
                    fixture.missing
                )
            } catch {
                missingEnumerationThrew = true
            }

            try expect(
                missingEnumerationThrew,
                "missing directory enumeration must throw"
            )

            do {
                _ = try DirectoryInspector(
                    fixture.missing
                ).entries()

                throw TestFailure(
                    message: "directory inspector on missing path must throw"
                )
            } catch let error as FileSystemError {
                try expectEqual(
                    error.operation,
                    .enumerate_directory,
                    "directory error operation"
                )
                try expectEqual(
                    error.url,
                    fixture.missing.standardizedFileURL,
                    "directory error url"
                )
                try expectEqual(
                    error.reason,
                    .not_found,
                    "directory error reason"
                )
            }
        }
    }

    static func testFileSystemBaselineInstrumentation() throws {
        try withFileSystemBenchmarkFixture(
            heavy: false
        ) { fixture in
            var counters = FileSystemBaselineCounters()

            try pathShapedExpansion(
                from: fixture.mixedTree,
                fileSystem: .default,
                counters: &counters
            )

            try expect(
                counters.directoriesEnumerated > 1,
                "path-shaped instrumentation must count expansions"
            )
            try expect(
                counters.entriesReturned > counters.directoriesEnumerated,
                "path-shaped instrumentation must count returned entries"
            )
            try expectEqual(
                counters.metadataInspections,
                0,
                "path-shaped expansion metadata inspections"
            )
            try expectEqual(
                counters.emptinessProbes,
                0,
                "path-shaped expansion emptiness probes"
            )
        }
    }
}