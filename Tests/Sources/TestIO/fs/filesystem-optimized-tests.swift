import Foundation
import IO

extension TestIO {
    static func testCFileSystemEquivalence() throws {
        try withFileSystemFixture(
            wideCount: 96,
            deepDepth: 12
        ) { fixture in
            let hidden = fixture.root.appendingPathComponent(".hidden")
            try writeFixtureFile(hidden, contents: "hidden\n")

            let unicode = fixture.root.appendingPathComponent(
                "føø-犬.txt"
            )
            try writeFixtureFile(
                unicode,
                contents: "unicode\n"
            )

            let cDirect = try FileSystem.c
                .directory
                .entries(fixture.root)
            let foundationDirect = try FileSystem.foundation
                .directory
                .entries(fixture.root)

            try expectEqual(
                entryMap(cDirect),
                entryMap(foundationDirect),
                "c direct enumeration"
            )

            try expectEqual(
                cDirect.map {
                    "\($0.url.lastPathComponent)=\($0.url.hasDirectoryPath)"
                }.sorted(),
                foundationDirect.map {
                    "\($0.url.lastPathComponent)=\($0.url.hasDirectoryPath)"
                }.sorted(),
                "c URL directory semantics"
            )

            try expectEqual(
                entryMap(
                    try FileSystem.c.directory.entries(
                        fixture.root,
                        options: .skipsHiddenFiles
                    )
                ),
                entryMap(
                    try FileSystem.foundation.directory.entries(
                        fixture.root,
                        options: .skipsHiddenFiles
                    )
                ),
                "c hidden filtering"
            )

            try expectEqual(
                entryMap(
                    try FileSystem.c.directory.entries(
                        fixture.deepRoot,
                        recursive: true
                    ),
                    relativeTo: fixture.deepRoot
                ),
                entryMap(
                    try FileSystem.foundation.directory.entries(
                        fixture.deepRoot,
                        recursive: true
                    ),
                    relativeTo: fixture.deepRoot
                ),
                "c recursive enumeration"
            )

            for url in [
                fixture.regularFile,
                fixture.emptyDirectory,
                fixture.fileSymlink,
                fixture.directorySymlink,
                fixture.brokenSymlink,
                fixture.fifo,
                fixture.missing,
            ] {
                let foundation = try FileInspector(
                    url,
                    fileSystem: .foundation
                ).inspect()

                let c = try FileInspector(
                    url,
                    fileSystem: .c
                ).inspect()

                try expectEqual(
                    c.existed,
                    foundation.existed,
                    "c metadata existence for \(url.lastPathComponent)"
                )
                try expectEqual(
                    c.byteCount,
                    foundation.byteCount,
                    "c metadata byte count for \(url.lastPathComponent)"
                )
                try expectEqual(
                    c.identity,
                    foundation.identity,
                    "c metadata identity for \(url.lastPathComponent)"
                )
                try expectEqual(
                    c.kind,
                    foundation.kind,
                    "c metadata kind for \(url.lastPathComponent)"
                )

                if let lhs = c.modifiedAt,
                   let rhs = foundation.modifiedAt
                {
                    try expect(
                        abs(lhs.timeIntervalSince(rhs)) < 0.001,
                        "c metadata modified date for \(url.lastPathComponent)"
                    )
                } else {
                    try expectEqual(
                        c.modifiedAt,
                        foundation.modifiedAt,
                        "c metadata modified date presence for \(url.lastPathComponent)"
                    )
                }

                try expectEqual(
                    FileSystem.c.exists(url),
                    FileSystem.foundation.exists(url),
                    "c exists probe for \(url.lastPathComponent)"
                )
            }

            try expectEqual(
                try DirectoryInspector(
                    fixture.emptyDirectory,
                    fileSystem: .c
                ).isEmpty(),
                try DirectoryInspector(
                    fixture.emptyDirectory,
                    fileSystem: .foundation
                ).isEmpty(),
                "c empty-directory probe"
            )

            try expectEqual(
                try DirectoryInspector(
                    fixture.nestedDirectory,
                    fileSystem: .c
                ).isEmpty(),
                try DirectoryInspector(
                    fixture.nestedDirectory,
                    fileSystem: .foundation
                ).isEmpty(),
                "c non-empty-directory probe"
            )

            let cEntries = entryMap(
                try FileSystem.c.directory.entries(
                    fixture.root
                )
            )

            try expectEqual(
                entryMap(
                    try FileSystem.default.directory.entries(
                        fixture.root
                    )
                ),
                cEntries,
                "FileSystem.default uses c implementation"
            )

            try expectEqual(
                entryMap(
                    try FileSystem().directory.entries(
                        fixture.root
                    )
                ),
                cEntries,
                "FileSystem() uses default c implementation"
            )

            let defaultMetadata = try FileInspector(
                fixture.regularFile
            ).inspect()
            let cMetadata = try FileInspector(
                fixture.regularFile,
                fileSystem: .c
            ).inspect()

            try expectEqual(
                defaultMetadata,
                cMetadata,
                "FileInspector default uses c implementation"
            )
        }
    }

    static func testCDirectoryInspectorStrategy() throws {
        try withFileSystemFixture { fixture in
            let foundation = try DirectoryInspector(
                fixture.nestedDirectory,
                fileSystem: .foundation
            ).entries()

            let c = try DirectoryInspector(
                fixture.nestedDirectory,
                fileSystem: .c
            ).entries()

            try expectEqual(
                c.count,
                foundation.count,
                "DirectoryInspector strategy entry count"
            )

            for (lhs, rhs) in zip(c, foundation) {
                try expectEqual(
                    lhs.url.lastPathComponent,
                    rhs.url.lastPathComponent,
                    "DirectoryInspector strategy child"
                )
                try expectEqual(
                    lhs.existed,
                    rhs.existed,
                    "DirectoryInspector strategy existence"
                )
                try expectEqual(
                    lhs.byteCount,
                    rhs.byteCount,
                    "DirectoryInspector strategy byte count"
                )
                try expectEqual(
                    lhs.identity,
                    rhs.identity,
                    "DirectoryInspector strategy identity"
                )
                try expectEqual(
                    lhs.kind,
                    rhs.kind,
                    "DirectoryInspector strategy kind"
                )
            }

            var missingProbeThrew = false

            do {
                _ = try DirectoryInspector(
                    fixture.missing,
                    fileSystem: .c
                ).isEmpty()
            } catch {
                missingProbeThrew = true
            }

            try expect(
                missingProbeThrew,
                "c missing-directory emptiness probe"
            )
        }
    }

    private static func entryMap(
        _ entries: [FileSystemEntry],
        relativeTo root: URL? = nil
    ) -> [String: FileKind] {
        Dictionary(
            uniqueKeysWithValues: entries.map { entry in
                let key: String

                if let root {
                    let rootPath = root.standardizedFileURL.path
                    let entryPath = entry.url.standardizedFileURL.path

                    if entryPath.hasPrefix(rootPath + "/") {
                        key = String(
                            entryPath.dropFirst(rootPath.count + 1)
                        )
                    } else {
                        key = entryPath
                    }
                } else {
                    key = entry.url.lastPathComponent
                }

                return (key, entry.kind)
            }
        )
    }
}
