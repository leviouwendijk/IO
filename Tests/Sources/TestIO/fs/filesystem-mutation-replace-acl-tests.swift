import Foundation
import IO

#if canImport(Darwin)
import Darwin
#endif

extension TestIO {
    static func testFileSystemMutationReplaceACLEquivalence() throws {
        #if canImport(Darwin)
        for scenario in [
            ReplaceACLScenario.both_distinct,
            .original_only,
            .replacement_only,
        ] {
            let foundation =
                try replaceACLOutcome(
                    fileSystem:
                        .foundation,
                    scenario:
                        scenario,
                    suffix:
                        "foundation"
                )
            let native =
                try replaceACLOutcome(
                    fileSystem:
                        .c,
                    scenario:
                        scenario,
                    suffix:
                        "c"
                )

            try expectEqual(
                native.acl,
                foundation.acl,
                "replace ACL differs for \(scenario.rawValue)"
            )
            try expectEqual(
                native.bytes,
                foundation.bytes,
                "replace bytes differ for \(scenario.rawValue)"
            )
            try expectEqual(
                native.replacementExists,
                foundation.replacementExists,
                "replace source cleanup differs for \(scenario.rawValue)"
            )
        }
        #endif
    }
}

#if canImport(Darwin)
extension TestIO {
    enum ReplaceACLScenario:
        String
    {
        case both_distinct
        case original_only
        case replacement_only
    }

    struct ReplaceACLOutcome {
        let acl: String?
        let bytes: [UInt8]
        let replacementExists: Bool
    }

    static func replaceACLOutcome(
        fileSystem: FileSystem,
        scenario:
            ReplaceACLScenario,
        suffix: String
    ) throws -> ReplaceACLOutcome {
        let root =
            temporaryFileSystemRoot(
                prefix:
                    "io-fs-replace-acl-\(scenario.rawValue)-\(suffix)"
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
            "original".utf8
        ).write(
            to: original
        )
        try Data(
            "replacement".utf8
        ).write(
            to: replacement
        )

        switch scenario {
        case .both_distinct:
            try replaceACLAddEntry(
                "everyone allow read",
                to: original
            )
            try replaceACLAddEntry(
                "everyone allow read,readattr",
                to: replacement
            )

        case .original_only:
            try replaceACLAddEntry(
                "everyone allow read",
                to: original
            )

        case .replacement_only:
            try replaceACLAddEntry(
                "everyone allow read,readattr",
                to: replacement
            )
        }

        try fileSystem.replace(
            original,
            with: replacement
        )

        return .init(
            acl:
                try replaceACLText(
                    original
                ),
            bytes:
                Array(
                    try Data(
                        contentsOf:
                            original
                    )
                ),
            replacementExists:
                manager.fileExists(
                    atPath:
                        replacement.path
                )
        )
    }

    static func replaceACLAddEntry(
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
            let data =
                errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message =
                String(
                    data: data,
                    encoding: .utf8
                ) ?? ""

            throw TestFailure(
                message:
                    "replace ACL setup failed: \(message)"
            )
        }
    }

    static func replaceACLText(
        _ url: URL
    ) throws -> String? {
        try url.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                throw TestFailure(
                    message:
                        "replace ACL path borrow failed"
                )
            }

            errno = 0

            guard let acl =
                    acl_get_file(
                        pointer,
                        ACL_TYPE_EXTENDED
                    )
            else {
                if errno == ENOENT {
                    return nil
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

            var length: ssize_t = 0

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
}
#endif
