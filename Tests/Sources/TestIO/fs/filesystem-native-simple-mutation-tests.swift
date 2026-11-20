import Foundation
import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    static func testNativeSimpleMutationErrorModel() throws {
        let root = temporaryURL(
            name: "native-simple-mutation-errors"
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

        do {
            try FileSystem.c.remove(
                root.appendingPathComponent(
                    "missing"
                )
            )

            throw TestFailure(
                message:
                    "native remove missing path must fail"
            )
        } catch let error as FileSystemError {
            try expectEqual(
                error.operation,
                .remove,
                "native remove operation"
            )
            try expectEqual(
                error.reason,
                .not_found,
                "native remove missing reason"
            )
        }

        do {
            try FileSystem.c.directory.create(
                root
                    .appendingPathComponent(
                        "missing-parent",
                        isDirectory: true
                    )
                    .appendingPathComponent(
                        "child",
                        isDirectory: true
                    ),
                intermediates: false
            )

            throw TestFailure(
                message:
                    "native create without intermediates must fail"
            )
        } catch let error as FileSystemError {
            try expectEqual(
                error.operation,
                .create_directory,
                "native create operation"
            )
            try expectEqual(
                error.reason,
                .not_found,
                "native create missing-parent reason"
            )
        }

        let source =
            root.appendingPathComponent(
                "source"
            )
        let destination =
            root.appendingPathComponent(
                "destination"
            )

        try Data(
            "source".utf8
        ).write(
            to: source
        )
        try Data(
            "destination".utf8
        ).write(
            to: destination
        )

        do {
            try FileSystem.c.move(
                source,
                to: destination
            )

            throw TestFailure(
                message:
                    "native no-replace move must reject collision"
            )
        } catch let error as FileSystemError {
            try expectEqual(
                error.operation,
                .move,
                "native collision move operation"
            )
            try expectEqual(
                error.reason,
                .already_exists,
                "native collision move reason"
            )
        }

        try expectEqual(
            Array(
                try Data(
                    contentsOf: source
                )
            ),
            Array(
                "source".utf8
            ),
            "move collision preserves source"
        )
        try expectEqual(
            Array(
                try Data(
                    contentsOf: destination
                )
            ),
            Array(
                "destination".utf8
            ),
            "move collision preserves destination"
        )
    }

    static func testNativeSimpleMutationLexicalStandardization() throws {
        let root = temporaryURL(
            name: "native-simple-mutation-standardization"
        )
        let physical =
            root.appendingPathComponent(
                "physical",
                isDirectory: true
            )
        let deep =
            physical.appendingPathComponent(
                "deep",
                isDirectory: true
            )
        let link =
            root.appendingPathComponent(
                "link"
            )

        try FileManager.default.createDirectory(
            at: deep,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath:
                "physical/deep"
        )

        defer {
            try? FileManager.default.removeItem(
                at: root
            )
        }

        let createInput =
            URL(
                fileURLWithPath:
                    root.path
                    + "/link/../created",
                isDirectory: true
            )
        let createExpected =
            createInput.standardizedFileURL

        try FileSystem.c.directory.create(
            createInput,
            intermediates: false
        )

        try expectEqual(
            FileManager.default.fileExists(
                atPath:
                    createExpected.path
            ),
            true,
            "create dotdot matches Foundation file-path standardization"
        )

        let rootVictim =
            root.appendingPathComponent(
                "victim"
            )
        let physicalVictim =
            physical.appendingPathComponent(
                "victim"
            )

        try Data(
            "root".utf8
        ).write(
            to: rootVictim
        )
        try Data(
            "physical".utf8
        ).write(
            to: physicalVictim
        )

        let removeInput =
            URL(
                fileURLWithPath:
                    root.path
                    + "/link/../victim"
            )
        let removeExpected =
            removeInput.standardizedFileURL
        let removeAlternate =
            removeExpected.path
                == rootVictim.path
            ? physicalVictim
            : rootVictim

        try FileSystem.c.remove(
            removeInput
        )

        try expectEqual(
            FileManager.default.fileExists(
                atPath:
                    removeExpected.path
            ),
            false,
            "remove dotdot matches Foundation file-path standardization"
        )

        if removeAlternate.path
            != removeExpected.path
        {
            try expectEqual(
                FileManager.default.fileExists(
                    atPath:
                        removeAlternate.path
                ),
                true,
                "remove dotdot preserves the non-standardized alternate"
            )
        }

        let rootSource =
            root.appendingPathComponent(
                "source"
            )
        let rootDestination =
            root.appendingPathComponent(
                "destination"
            )
        let physicalSource =
            physical.appendingPathComponent(
                "source"
            )
        let physicalDestination =
            physical.appendingPathComponent(
                "destination"
            )

        let rootBytes =
            Array(
                "root-source".utf8
            )
        let physicalBytes =
            Array(
                "physical-source".utf8
            )

        try Data(
            rootBytes
        ).write(
            to: rootSource
        )
        try Data(
            physicalBytes
        ).write(
            to: physicalSource
        )

        let moveSource =
            URL(
                fileURLWithPath:
                    root.path
                    + "/link/../source"
            )
        let moveDestination =
            URL(
                fileURLWithPath:
                    root.path
                    + "/link/../destination"
            )
        let moveExpectedSource =
            moveSource.standardizedFileURL
        let moveExpectedDestination =
            moveDestination.standardizedFileURL
        let expectedBytes =
            moveExpectedSource.path
                == rootSource.path
            ? rootBytes
            : physicalBytes
        let moveAlternateSource =
            moveExpectedSource.path
                == rootSource.path
            ? physicalSource
            : rootSource
        let moveAlternateDestination =
            moveExpectedDestination.path
                == rootDestination.path
            ? physicalDestination
            : rootDestination

        try FileSystem.c.move(
            moveSource,
            to: moveDestination
        )

        try expectEqual(
            Array(
                try Data(
                    contentsOf:
                        moveExpectedDestination
                )
            ),
            expectedBytes,
            "move dotdot matches Foundation file-path standardization"
        )

        if moveAlternateSource.path
            != moveExpectedSource.path
        {
            try expectEqual(
                FileManager.default.fileExists(
                    atPath:
                        moveAlternateSource.path
                ),
                true,
                "move dotdot preserves alternate source"
            )
        }

        if moveAlternateDestination.path
            != moveExpectedDestination.path
        {
            try expectEqual(
                FileManager.default.fileExists(
                    atPath:
                        moveAlternateDestination.path
                ),
                false,
                "move dotdot does not create alternate destination"
            )
        }
    }
}
