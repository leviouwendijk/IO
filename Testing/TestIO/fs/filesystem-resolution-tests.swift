import Foundation
import IO

extension TestIO {
    struct FileSystemResolutionCase {
        let name: String
        let input: URL
    }

    static func testFileSystemResolutionReferenceEquivalence() throws {
        try withFileSystemResolutionFixture {
            root,
            cases in

            for item in cases {
                let foundation = FileSystem.foundation.resolve(
                    item.input
                )
                let c = FileSystem.c.resolve(
                    item.input
                )

                try expectEqual(
                    c,
                    foundation,
                    "resolution differs for \(item.name)"
                )

                try expect(
                    foundation.isFileURL,
                    "resolved path must remain a file URL for \(item.name)"
                )

                _ = root
            }
        }
    }

    static func runFileSystemResolutionCharacterization() throws {
        try withFileSystemResolutionFixture {
            root,
            cases in

            print("")
            print("filesystem resolution characterization")
            print("foundation: FileSystem.foundation.resolve")
            print("c: FileSystem.c.resolve")
            print("")

            for item in cases {
                let foundation = FileSystem.foundation.resolve(
                    item.input
                )
                let c = FileSystem.c.resolve(
                    item.input
                )

                print(item.name)
                print(
                    "  input: "
                        + resolutionDisplayPath(
                            item.input,
                            root: root
                        )
                )
                print(
                    "  foundation: "
                        + resolutionDisplayPath(
                            foundation,
                            root: root
                        )
                )
                print(
                    "  c: "
                        + resolutionDisplayPath(
                            c,
                            root: root
                        )
                )
                print("")
            }
        }
    }
}

extension TestIO {
    static func withFileSystemResolutionFixture(
        _ body:
            (
                URL,
                [FileSystemResolutionCase]
            ) throws -> Void
    ) throws {
        let root = temporaryFileSystemRoot(
            prefix: "io-fs-resolution"
        )
        let manager = FileManager.default

        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        defer {
            try? manager.removeItem(
                at: root
            )
        }

        let target = root.appendingPathComponent(
            "target.txt"
        )
        try writeFixtureFile(
            target,
            contents: "target\n"
        )

        let directory = root.appendingPathComponent(
            "directory",
            isDirectory: true
        )
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )

        let child = directory.appendingPathComponent(
            "child.txt"
        )
        try writeFixtureFile(
            child,
            contents: "child\n"
        )

        let nested = root.appendingPathComponent(
            "nested",
            isDirectory: true
        )
        try manager.createDirectory(
            at: nested,
            withIntermediateDirectories: false
        )

        try manager.createSymbolicLink(
            atPath:
                root.appendingPathComponent(
                    "relative-link"
                ).path,
            withDestinationPath: "target.txt"
        )

        try manager.createSymbolicLink(
            atPath:
                root.appendingPathComponent(
                    "absolute-link"
                ).path,
            withDestinationPath: target.path
        )

        try manager.createSymbolicLink(
            atPath:
                root.appendingPathComponent(
                    "directory-link"
                ).path,
            withDestinationPath: "directory"
        )

        try manager.createSymbolicLink(
            atPath:
                root.appendingPathComponent(
                    "chain-a"
                ).path,
            withDestinationPath: "chain-b"
        )
        try manager.createSymbolicLink(
            atPath:
                root.appendingPathComponent(
                    "chain-b"
                ).path,
            withDestinationPath: "relative-link"
        )

        try manager.createSymbolicLink(
            atPath:
                nested.appendingPathComponent(
                    "up-link"
                ).path,
            withDestinationPath: "../target.txt"
        )

        try manager.createSymbolicLink(
            atPath:
                root.appendingPathComponent(
                    "dotdot-link"
                ).path,
            withDestinationPath:
                "./directory/../target.txt"
        )

        try manager.createSymbolicLink(
            atPath:
                root.appendingPathComponent(
                    "broken-link"
                ).path,
            withDestinationPath: "missing-target"
        )

        try manager.createSymbolicLink(
            atPath:
                root.appendingPathComponent(
                    "loop-a"
                ).path,
            withDestinationPath: "loop-b"
        )
        try manager.createSymbolicLink(
            atPath:
                root.appendingPathComponent(
                    "loop-b"
                ).path,
            withDestinationPath: "loop-a"
        )

        let cases: [FileSystemResolutionCase] = [
            .init(
                name: "regular-file",
                input: target
            ),
            .init(
                name: "relative-file-link",
                input:
                    root.appendingPathComponent(
                        "relative-link"
                    )
            ),
            .init(
                name: "absolute-file-link",
                input:
                    root.appendingPathComponent(
                        "absolute-link"
                    )
            ),
            .init(
                name: "directory-link",
                input:
                    root.appendingPathComponent(
                        "directory-link",
                        isDirectory: true
                    )
            ),
            .init(
                name: "child-through-directory-link",
                input:
                    root
                        .appendingPathComponent(
                            "directory-link",
                            isDirectory: true
                        )
                        .appendingPathComponent(
                            "child.txt"
                        )
            ),
            .init(
                name: "symlink-chain",
                input:
                    root.appendingPathComponent(
                        "chain-a"
                    )
            ),
            .init(
                name: "parent-relative-target",
                input:
                    nested.appendingPathComponent(
                        "up-link"
                    )
            ),
            .init(
                name: "target-containing-dotdot",
                input:
                    root.appendingPathComponent(
                        "dotdot-link"
                    )
            ),
            .init(
                name: "broken-link",
                input:
                    root.appendingPathComponent(
                        "broken-link"
                    )
            ),
            .init(
                name: "missing-leaf",
                input:
                    root.appendingPathComponent(
                        "missing-leaf"
                    )
            ),
            .init(
                name: "missing-child-in-existing-directory",
                input:
                    directory.appendingPathComponent(
                        "missing-child"
                    )
            ),
            .init(
                name: "missing-child-through-directory-link",
                input:
                    root
                        .appendingPathComponent(
                            "directory-link",
                            isDirectory: true
                        )
                        .appendingPathComponent(
                            "missing-child"
                        )
            ),
            .init(
                name: "symlink-loop",
                input:
                    root.appendingPathComponent(
                        "loop-a"
                    )
            ),
            .init(
                name: "lexical-dotdot",
                input: URL(
                    fileURLWithPath:
                        root.path
                        + "/directory/../target.txt"
                )
            ),
        ]

        try body(
            root,
            cases
        )
    }

    static func resolutionDisplayPath(
        _ url: URL,
        root: URL
    ) -> String {
        let path = url.path
        let rootPath = root.path

        if path == rootPath {
            return "."
        }

        let prefix = rootPath + "/"

        if path.hasPrefix(
            prefix
        ) {
            return String(
                path.dropFirst(
                    prefix.count
                )
            )
        }

        return path
    }
}
