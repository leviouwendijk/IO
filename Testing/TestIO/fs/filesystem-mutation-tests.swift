import Foundation
import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    private struct MutationTreeEntry: Equatable {
        enum Kind: String, Equatable {
            case missing
            case file
            case directory
            case symbolic_link
            case other
        }

        let relativePath: String
        let kind: Kind
        let permissions: UInt32?
        let bytes: [UInt8]?
        let symbolicLinkTarget: String?
    }

    private struct MutationOutcome: Equatable {
        let succeeded: Bool
        let tree: [MutationTreeEntry]
    }

    static func testFileSystemMutationCreateRemoveEquivalence() throws {
        try compareMutationScenario(
            "create-empty-directory",
            setup: { _ in },
            operation: { fileSystem, root in
                try fileSystem.directory.create(
                    root.appendingPathComponent(
                        "created",
                        isDirectory: true
                    ),
                    intermediates: false
                )
            }
        )

        try compareMutationScenario(
            "create-deep-intermediates",
            setup: { _ in },
            operation: { fileSystem, root in
                try fileSystem.directory.create(
                    root
                        .appendingPathComponent("a", isDirectory: true)
                        .appendingPathComponent("b", isDirectory: true)
                        .appendingPathComponent("c", isDirectory: true),
                    intermediates: true
                )
            }
        )

        try compareMutationScenario(
            "create-missing-parent-without-intermediates",
            setup: { _ in },
            operation: { fileSystem, root in
                try fileSystem.directory.create(
                    root
                        .appendingPathComponent("missing", isDirectory: true)
                        .appendingPathComponent("child", isDirectory: true),
                    intermediates: false
                )
            }
        )

        try compareMutationScenario(
            "create-existing-directory",
            setup: { root in
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(
                        "existing",
                        isDirectory: true
                    ),
                    withIntermediateDirectories: false
                )
            },
            operation: { fileSystem, root in
                try fileSystem.directory.create(
                    root.appendingPathComponent(
                        "existing",
                        isDirectory: true
                    ),
                    intermediates: true
                )
            }
        )

        try compareMutationScenario(
            "create-directory-attributes",
            setup: { _ in },
            operation: { fileSystem, root in
                try fileSystem.directory.create(
                    root.appendingPathComponent(
                        "permissions",
                        isDirectory: true
                    ),
                    intermediates: false,
                    attributes: [
                        .posixPermissions: NSNumber(
                            value: UInt16(0o750)
                        )
                    ]
                )
            }
        )

        try compareMutationScenario(
            "remove-regular-file",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("payload.bin"),
                    bytes: [0, 1, 2, 3, 255]
                )
            },
            operation: { fileSystem, root in
                try fileSystem.remove(
                    root.appendingPathComponent("payload.bin")
                )
            }
        )

        try compareMutationScenario(
            "remove-empty-directory",
            setup: { root in
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(
                        "empty",
                        isDirectory: true
                    ),
                    withIntermediateDirectories: false
                )
            },
            operation: { fileSystem, root in
                try fileSystem.remove(
                    root.appendingPathComponent(
                        "empty",
                        isDirectory: true
                    )
                )
            }
        )

        try compareMutationScenario(
            "remove-nonempty-tree",
            setup: { root in
                let tree = root.appendingPathComponent(
                    "tree",
                    isDirectory: true
                )
                try mutationMakeTree(tree)
            },
            operation: { fileSystem, root in
                try fileSystem.remove(
                    root.appendingPathComponent(
                        "tree",
                        isDirectory: true
                    )
                )
            }
        )

        try compareMutationScenario(
            "remove-symbolic-link-not-target",
            setup: { root in
                let target = root.appendingPathComponent("target.txt")
                let link = root.appendingPathComponent("link.txt")

                try mutationWrite(
                    target,
                    bytes: Array("target".utf8)
                )
                try FileManager.default.createSymbolicLink(
                    atPath: link.path,
                    withDestinationPath: "target.txt"
                )
            },
            operation: { fileSystem, root in
                try fileSystem.remove(
                    root.appendingPathComponent("link.txt")
                )
            }
        )

        try compareMutationScenario(
            "remove-broken-symbolic-link",
            setup: { root in
                try FileManager.default.createSymbolicLink(
                    atPath: root.appendingPathComponent("broken").path,
                    withDestinationPath: "missing-target"
                )
            },
            operation: { fileSystem, root in
                try fileSystem.remove(
                    root.appendingPathComponent("broken")
                )
            }
        )

        try compareMutationScenario(
            "remove-missing",
            setup: { _ in },
            operation: { fileSystem, root in
                try fileSystem.remove(
                    root.appendingPathComponent("missing")
                )
            }
        )
    }

    static func testFileSystemMutationCopyEquivalence() throws {
        try compareMutationScenario(
            "copy-empty-file",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("source"),
                    bytes: []
                )
            },
            operation: { fileSystem, root in
                try fileSystem.copy(
                    root.appendingPathComponent("source"),
                    to: root.appendingPathComponent("destination")
                )
            }
        )

        try compareMutationScenario(
            "copy-regular-file",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("source"),
                    bytes: mutationPayload(count: 4096)
                )
            },
            operation: { fileSystem, root in
                try fileSystem.copy(
                    root.appendingPathComponent("source"),
                    to: root.appendingPathComponent("destination")
                )
            }
        )

        try compareMutationScenario(
            "copy-directory-tree",
            setup: { root in
                try mutationMakeTree(
                    root.appendingPathComponent(
                        "source",
                        isDirectory: true
                    )
                )
            },
            operation: { fileSystem, root in
                try fileSystem.copy(
                    root.appendingPathComponent(
                        "source",
                        isDirectory: true
                    ),
                    to: root.appendingPathComponent(
                        "destination",
                        isDirectory: true
                    )
                )
            }
        )

        try compareMutationScenario(
            "copy-symbolic-link",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("target"),
                    bytes: Array("target".utf8)
                )
                try FileManager.default.createSymbolicLink(
                    atPath: root.appendingPathComponent("source-link").path,
                    withDestinationPath: "target"
                )
            },
            operation: { fileSystem, root in
                try fileSystem.copy(
                    root.appendingPathComponent("source-link"),
                    to: root.appendingPathComponent("destination-link")
                )
            }
        )

        try compareMutationScenario(
            "copy-broken-symbolic-link",
            setup: { root in
                try FileManager.default.createSymbolicLink(
                    atPath: root.appendingPathComponent("source-link").path,
                    withDestinationPath: "missing-target"
                )
            },
            operation: { fileSystem, root in
                try fileSystem.copy(
                    root.appendingPathComponent("source-link"),
                    to: root.appendingPathComponent("destination-link")
                )
            }
        )

        try compareMutationScenario(
            "copy-existing-destination",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("source"),
                    bytes: Array("source".utf8)
                )
                try mutationWrite(
                    root.appendingPathComponent("destination"),
                    bytes: Array("destination".utf8)
                )
            },
            operation: { fileSystem, root in
                try fileSystem.copy(
                    root.appendingPathComponent("source"),
                    to: root.appendingPathComponent("destination")
                )
            }
        )

        try compareMutationScenario(
            "copy-missing-source",
            setup: { _ in },
            operation: { fileSystem, root in
                try fileSystem.copy(
                    root.appendingPathComponent("missing-source"),
                    to: root.appendingPathComponent("destination")
                )
            }
        )

        try compareMutationScenario(
            "copy-missing-destination-parent",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("source"),
                    bytes: Array("source".utf8)
                )
            },
            operation: { fileSystem, root in
                try fileSystem.copy(
                    root.appendingPathComponent("source"),
                    to: root
                        .appendingPathComponent(
                            "missing-parent",
                            isDirectory: true
                        )
                        .appendingPathComponent("destination")
                )
            }
        )
    }

    static func testFileSystemMutationMoveEquivalence() throws {
        try compareMutationScenario(
            "move-regular-file",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("source"),
                    bytes: mutationPayload(count: 4096)
                )
            },
            operation: { fileSystem, root in
                try fileSystem.move(
                    root.appendingPathComponent("source"),
                    to: root.appendingPathComponent("destination")
                )
            }
        )

        try compareMutationScenario(
            "move-directory-tree",
            setup: { root in
                try mutationMakeTree(
                    root.appendingPathComponent(
                        "source",
                        isDirectory: true
                    )
                )
            },
            operation: { fileSystem, root in
                try fileSystem.move(
                    root.appendingPathComponent(
                        "source",
                        isDirectory: true
                    ),
                    to: root.appendingPathComponent(
                        "destination",
                        isDirectory: true
                    )
                )
            }
        )

        try compareMutationScenario(
            "move-symbolic-link",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("target"),
                    bytes: Array("target".utf8)
                )
                try FileManager.default.createSymbolicLink(
                    atPath: root.appendingPathComponent("source-link").path,
                    withDestinationPath: "target"
                )
            },
            operation: { fileSystem, root in
                try fileSystem.move(
                    root.appendingPathComponent("source-link"),
                    to: root.appendingPathComponent("destination-link")
                )
            }
        )

        try compareMutationScenario(
            "move-existing-destination",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("source"),
                    bytes: Array("source".utf8)
                )
                try mutationWrite(
                    root.appendingPathComponent("destination"),
                    bytes: Array("destination".utf8)
                )
            },
            operation: { fileSystem, root in
                try fileSystem.move(
                    root.appendingPathComponent("source"),
                    to: root.appendingPathComponent("destination")
                )
            }
        )

        try compareMutationScenario(
            "move-missing-source",
            setup: { _ in },
            operation: { fileSystem, root in
                try fileSystem.move(
                    root.appendingPathComponent("missing-source"),
                    to: root.appendingPathComponent("destination")
                )
            }
        )

        try compareMutationScenario(
            "move-same-path",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("same"),
                    bytes: Array("same".utf8)
                )
            },
            operation: { fileSystem, root in
                let same = root.appendingPathComponent("same")
                try fileSystem.move(
                    same,
                    to: same
                )
            }
        )

        try compareMutationScenario(
            "move-missing-destination-parent",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("source"),
                    bytes: Array("source".utf8)
                )
            },
            operation: { fileSystem, root in
                try fileSystem.move(
                    root.appendingPathComponent("source"),
                    to: root
                        .appendingPathComponent(
                            "missing-parent",
                            isDirectory: true
                        )
                        .appendingPathComponent("destination")
                )
            }
        )
    }

    static func testFileSystemMutationReplaceEquivalence() throws {
        try compareMutationScenario(
            "replace-regular-file",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("original"),
                    bytes: Array("original".utf8)
                )
                try mutationWrite(
                    root.appendingPathComponent("replacement"),
                    bytes: Array("replacement".utf8)
                )
            },
            operation: { fileSystem, root in
                try fileSystem.replace(
                    root.appendingPathComponent("original"),
                    with: root.appendingPathComponent("replacement")
                )
            }
        )

        try compareMutationScenario(
            "replace-empty-with-nonempty",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("original"),
                    bytes: []
                )
                try mutationWrite(
                    root.appendingPathComponent("replacement"),
                    bytes: mutationPayload(count: 4096)
                )
            },
            operation: { fileSystem, root in
                try fileSystem.replace(
                    root.appendingPathComponent("original"),
                    with: root.appendingPathComponent("replacement")
                )
            }
        )

        try compareMutationScenario(
            "replace-missing-original",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("replacement"),
                    bytes: Array("replacement".utf8)
                )
            },
            operation: { fileSystem, root in
                try fileSystem.replace(
                    root.appendingPathComponent("missing-original"),
                    with: root.appendingPathComponent("replacement")
                )
            }
        )

        try compareMutationScenario(
            "replace-missing-replacement",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("original"),
                    bytes: Array("original".utf8)
                )
            },
            operation: { fileSystem, root in
                try fileSystem.replace(
                    root.appendingPathComponent("original"),
                    with: root.appendingPathComponent("missing-replacement")
                )
            }
        )

        try compareMutationScenario(
            "replace-symbolic-link",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("target"),
                    bytes: Array("target".utf8)
                )
                try FileManager.default.createSymbolicLink(
                    atPath: root.appendingPathComponent("original").path,
                    withDestinationPath: "target"
                )
                try mutationWrite(
                    root.appendingPathComponent("replacement"),
                    bytes: Array("replacement".utf8)
                )
            },
            operation: { fileSystem, root in
                try fileSystem.replace(
                    root.appendingPathComponent("original"),
                    with: root.appendingPathComponent("replacement")
                )
            }
        )
    }

    static func testFileSystemMutationFailurePostconditions() throws {
        try compareMutationScenario(
            "copy-collision-preserves-tree",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("source"),
                    bytes: Array("source".utf8)
                )
                try mutationWrite(
                    root.appendingPathComponent("destination"),
                    bytes: Array("destination".utf8)
                )
            },
            operation: { fileSystem, root in
                try fileSystem.copy(
                    root.appendingPathComponent("source"),
                    to: root.appendingPathComponent("destination")
                )
            }
        )

        try compareMutationScenario(
            "move-collision-preserves-tree",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("source"),
                    bytes: Array("source".utf8)
                )
                try mutationWrite(
                    root.appendingPathComponent("destination"),
                    bytes: Array("destination".utf8)
                )
            },
            operation: { fileSystem, root in
                try fileSystem.move(
                    root.appendingPathComponent("source"),
                    to: root.appendingPathComponent("destination")
                )
            }
        )

        try compareMutationScenario(
            "create-no-intermediates-preserves-tree",
            setup: { root in
                try mutationWrite(
                    root.appendingPathComponent("sentinel"),
                    bytes: Array("sentinel".utf8)
                )
            },
            operation: { fileSystem, root in
                try fileSystem.directory.create(
                    root
                        .appendingPathComponent(
                            "missing",
                            isDirectory: true
                        )
                        .appendingPathComponent(
                            "child",
                            isDirectory: true
                        ),
                    intermediates: false
                )
            }
        )
    }
}

private extension TestIO {
    static func compareMutationScenario(
        _ name: String,
        setup: (URL) throws -> Void,
        operation: (FileSystem, URL) throws -> Void
    ) throws {
        let foundation = try mutationOutcome(
            name: "\(name)-foundation",
            setup: setup
        ) { root in
            try operation(
                .foundation,
                root
            )
        }

        let c = try mutationOutcome(
            name: "\(name)-c",
            setup: setup
        ) { root in
            try operation(
                .c,
                root
            )
        }

        try expectEqual(
            c,
            foundation,
            "mutation semantics differ for \(name)"
        )
    }

    private static func mutationOutcome(
        name: String,
        setup: (URL) throws -> Void,
        operation: (URL) throws -> Void
    ) throws -> MutationOutcome {
        let root = temporaryFileSystemRoot(
            prefix: "io-fs-mutation-\(name)"
        )

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        defer {
            try? FileManager.default.removeItem(
                at: root
            )
        }

        try setup(root)

        let succeeded: Bool

        do {
            try operation(root)
            succeeded = true
        } catch {
            succeeded = false
        }

        return .init(
            succeeded: succeeded,
            tree: try mutationTreeSnapshot(root)
        )
    }

    private static func mutationTreeSnapshot(
        _ root: URL
    ) throws -> [MutationTreeEntry] {
        var result: [MutationTreeEntry] = []

        guard mutationMetadata(root) != nil else {
            return [
                .init(
                    relativePath: ".",
                    kind: .missing,
                    permissions: nil,
                    bytes: nil,
                    symbolicLinkTarget: nil
                )
            ]
        }

        try appendMutationTreeSnapshot(
            root,
            relativePath: ".",
            to: &result
        )

        return result
    }

    private static func appendMutationTreeSnapshot(
        _ url: URL,
        relativePath: String,
        to result: inout [MutationTreeEntry]
    ) throws {
        guard let metadata = mutationMetadata(url) else {
            result.append(
                .init(
                    relativePath: relativePath,
                    kind: .missing,
                    permissions: nil,
                    bytes: nil,
                    symbolicLinkTarget: nil
                )
            )
            return
        }

        let mode = metadata.st_mode
        let type = mode & mode_t(S_IFMT)
        let permissions = UInt32(
            mode & mode_t(0o7777)
        )

        if type == mode_t(S_IFREG) {
            result.append(
                .init(
                    relativePath: relativePath,
                    kind: .file,
                    permissions: permissions,
                    bytes: Array(
                        try Data(
                            contentsOf: url
                        )
                    ),
                    symbolicLinkTarget: nil
                )
            )
            return
        }

        if type == mode_t(S_IFLNK) {
            result.append(
                .init(
                    relativePath: relativePath,
                    kind: .symbolic_link,
                    permissions: permissions,
                    bytes: nil,
                    symbolicLinkTarget:
                        try FileManager.default.destinationOfSymbolicLink(
                            atPath: url.path
                        )
                )
            )
            return
        }

        guard type == mode_t(S_IFDIR) else {
            result.append(
                .init(
                    relativePath: relativePath,
                    kind: .other,
                    permissions: permissions,
                    bytes: nil,
                    symbolicLinkTarget: nil
                )
            )
            return
        }

        result.append(
            .init(
                relativePath: relativePath,
                kind: .directory,
                permissions: permissions,
                bytes: nil,
                symbolicLinkTarget: nil
            )
        )

        let names = try FileManager.default.contentsOfDirectory(
            atPath: url.path
        ).sorted()

        for name in names {
            let childRelativePath = relativePath == "."
                ? name
                : "\(relativePath)/\(name)"

            try appendMutationTreeSnapshot(
                url.appendingPathComponent(
                    name,
                    isDirectory: false
                ),
                relativePath: childRelativePath,
                to: &result
            )
        }
    }

    static func mutationMetadata(
        _ url: URL
    ) -> stat? {
        var info = stat()

        guard url.path.withCString({
            lstat(
                $0,
                &info
            )
        }) == 0 else {
            return nil
        }

        return info
    }

    static func mutationWrite(
        _ url: URL,
        bytes: [UInt8]
    ) throws {
        try Data(
            bytes
        ).write(
            to: url
        )
    }

    static func mutationPayload(
        count: Int
    ) -> [UInt8] {
        (0..<count).map {
            UInt8(
                truncatingIfNeeded: $0 &* 31
            )
        }
    }

    static func mutationMakeTree(
        _ root: URL
    ) throws {
        let manager = FileManager.default

        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        try mutationWrite(
            root.appendingPathComponent("root.txt"),
            bytes: Array("root".utf8)
        )

        for branch in 0..<4 {
            let directory = root.appendingPathComponent(
                "branch-\(branch)",
                isDirectory: true
            )

            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )

            for fileIndex in 0..<4 {
                try mutationWrite(
                    directory.appendingPathComponent(
                        "file-\(fileIndex).bin"
                    ),
                    bytes: mutationPayload(
                        count: 257 + fileIndex
                    )
                )
            }
        }

        let link = root.appendingPathComponent("root-link")
        try manager.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "root.txt"
        )

        let broken = root.appendingPathComponent("broken-link")
        try manager.createSymbolicLink(
            atPath: broken.path,
            withDestinationPath: "missing-target"
        )
    }
}
