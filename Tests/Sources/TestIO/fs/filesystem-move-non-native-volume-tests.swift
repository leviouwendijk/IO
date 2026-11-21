import Foundation
@_spi(Testing) import IO

extension TestIO {
    /// A no-replace move on a volume without `RENAME_EXCL` (exFAT) falls back
    /// to `lstat` + `rename`: it moves, and still refuses an occupied destination.
    ///
    /// Darwin only. Needs `hdiutil` to create and attach an exFAT image; when it
    /// cannot (sandbox, CI without disk images) the test reports and passes.
    static func testMoveOnNonNativeVolume() throws {
        #if os(macOS)
        let root = temporaryURL(
            name: "move-non-native-volume"
        )

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let image = root.appendingPathComponent(
            "volume.dmg"
        )
        let mountPoint = root.appendingPathComponent(
            "mount",
            isDirectory: true
        )

        defer {
            _ = try? runTool(
                "/usr/bin/hdiutil",
                [
                    "detach",
                    mountPoint.path,
                    "-force",
                ]
            )
            try? FileManager.default.removeItem(
                at: root
            )
        }

        guard (try? runTool(
            "/usr/bin/hdiutil",
            [
                "create",
                "-size", "8m",
                "-fs", "ExFAT",
                "-volname", "tio-exfat",
                "-quiet",
                image.path,
            ]
        )) == 0,
              (try? runTool(
                "/usr/bin/hdiutil",
                [
                    "attach",
                    image.path,
                    "-mountpoint", mountPoint.path,
                    "-nobrowse",
                    "-quiet",
                ]
              )) == 0
        else {
            print(
                "  move-non-native-volume: hdiutil unavailable; exFAT path not exercised"
            )
            return
        }

        let source = mountPoint.appendingPathComponent(
            "source.txt"
        )
        let destination = mountPoint
            .appendingPathComponent(
                "nested",
                isDirectory: true
            )
            .appendingPathComponent(
                "destination.txt"
            )
        let occupied = mountPoint.appendingPathComponent(
            "occupied.txt"
        )

        try Data("source".utf8).write(
            to: source
        )
        try Data("occupied".utf8).write(
            to: occupied
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try FileSystem.c.move(
            source,
            to: destination
        )

        try expect(
            !FileManager.default.fileExists(
                atPath: source.path
            ),
            "exFAT move removes the source"
        )
        try expectEqual(
            try String(
                contentsOf: destination,
                encoding: .utf8
            ),
            "source",
            "exFAT move carries the content"
        )

        let directorySource = mountPoint.appendingPathComponent(
            "folder",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directorySource,
            withIntermediateDirectories: true
        )
        try Data("inner".utf8).write(
            to: directorySource.appendingPathComponent(
                "inner.txt"
            )
        )

        let directoryDestination = mountPoint.appendingPathComponent(
            "moved-folder",
            isDirectory: true
        )
        try FileSystem.c.move(
            directorySource,
            to: directoryDestination
        )
        try expect(
            FileManager.default.fileExists(
                atPath: directoryDestination
                    .appendingPathComponent(
                        "inner.txt"
                    )
                    .path
            ),
            "exFAT directory move carries its children"
        )

        // exFAT is case-insensitive: a case-only rename finds the source under
        // its other spelling, which is the same object, not a collision.
        let mixedCase = mountPoint.appendingPathComponent(
            "Photo.JPG"
        )
        let lowerCase = mountPoint.appendingPathComponent(
            "photo.jpg"
        )
        try Data("photo".utf8).write(
            to: mixedCase
        )
        try FileSystem.c.move(
            mixedCase,
            to: lowerCase
        )
        let names = try FileManager.default.contentsOfDirectory(
            atPath: mountPoint.path
        )
        try expect(
            names.contains(
                "photo.jpg"
            ),
            "exFAT case-only move takes the new spelling"
        )

        do {
            try FileSystem.c.move(
                destination,
                to: occupied
            )

            throw TestFailure(
                message:
                    "exFAT no-replace move must reject an occupied destination"
            )
        } catch let error as FileSystemError {
            try expectEqual(
                error.operation,
                .move,
                "exFAT collision operation"
            )
            try expectEqual(
                error.reason,
                .already_exists,
                "exFAT collision reason"
            )
        }

        try expectEqual(
            try String(
                contentsOf: occupied,
                encoding: .utf8
            ),
            "occupied",
            "exFAT collision preserves the destination"
        )
        try expectEqual(
            try String(
                contentsOf: destination,
                encoding: .utf8
            ),
            "source",
            "exFAT collision preserves the source"
        )
        #endif
    }

    #if os(macOS)
    private static func runTool(
        _ executable: String,
        _ arguments: [String]
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: executable
        )
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    #endif
}
