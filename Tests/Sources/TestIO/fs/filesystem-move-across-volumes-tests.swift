import Foundation
@_spi(Testing) import IO

extension TestIO {
    /// A move to another volume (`rename` → `EXDEV`) goes through IO's copy
    /// and removal. It moves files and directories, and a copy that cannot
    /// fit fails as `.copy` with the source intact and no destination.
    ///
    /// Darwin only; needs `hdiutil` for the second volume. Without it the
    /// test reports and passes.
    static func testMoveAcrossVolumes() throws {
        #if os(macOS)
        let root = temporaryURL(
            name: "move-across-volumes"
        )
        try FileSystem.default.directory.create(root, intermediates: true)
        let image = root.appendingPathComponent("volume.dmg")
        let mount = root.appendingPathComponent("mount", isDirectory: true)

        defer {
            _ = try? acrossVolumesTool("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? FileSystem.default.remove(root)
        }

        guard (try? acrossVolumesTool("/usr/bin/hdiutil", ["create", "-size", "8m", "-fs", "ExFAT", "-volname", "tio-xdev", "-quiet", image.path])) == 0,
              (try? acrossVolumesTool("/usr/bin/hdiutil", ["attach", image.path, "-mountpoint", mount.path, "-nobrowse", "-quiet"])) == 0
        else {
            print("  move-across-volumes: hdiutil unavailable; EXDEV path not exercised")
            return
        }

        // A file.
        let file = root.appendingPathComponent("file.txt")
        try Data("file\n".utf8).write(to: file)
        let movedFile = mount.appendingPathComponent("file.txt")
        try FileSystem.c.move(file, to: movedFile)
        try expect(!FileManager.default.fileExists(atPath: file.path), "file source removed")
        try expectEqual(try String(contentsOf: movedFile, encoding: .utf8), "file\n", "file content moved")

        // A directory tree.
        let tree = root.appendingPathComponent("tree", isDirectory: true)
        try FileSystem.default.directory.create(tree.appendingPathComponent("inner", isDirectory: true), intermediates: true)
        try Data("deep\n".utf8).write(to: tree.appendingPathComponent("inner/deep.txt"))
        let movedTree = mount.appendingPathComponent("tree", isDirectory: true)
        try FileSystem.c.move(tree, to: movedTree)
        try expect(!FileManager.default.fileExists(atPath: tree.path), "tree source removed")
        try expectEqual(
            try String(contentsOf: movedTree.appendingPathComponent("inner/deep.txt"), encoding: .utf8),
            "deep\n",
            "tree content moved"
        )

        // An occupied destination is refused; nothing moves.
        let again = root.appendingPathComponent("again.txt")
        try Data("again\n".utf8).write(to: again)
        do {
            try FileSystem.c.move(again, to: movedFile)
            throw TestFailure(message: "moving onto an occupied destination must fail")
        } catch let error as FileSystemError {
            try expectEqual(error.reason, .already_exists, "occupied destination reason")
        }
        try expect(FileManager.default.fileExists(atPath: again.path), "refused move keeps the source")
        try expectEqual(try String(contentsOf: movedFile, encoding: .utf8), "file\n", "refused move keeps the destination")

        // Too large for the volume: fails as a copy, leaves nothing behind.
        let large = root.appendingPathComponent("large.bin")
        try Data().write(to: large)
        guard truncate(large.path, off_t(32 << 20)) == 0 else {
            throw TestFailure(message: "sparse fixture")
        }
        let landed = mount.appendingPathComponent("large.bin")
        do {
            try FileSystem.c.move(large, to: landed)
            throw TestFailure(message: "a move larger than the volume must fail")
        } catch let error as FileSystemError {
            try expectEqual(error.operation, .copy, "full volume fails as the copy")
            try expectEqual(error.reason, .no_space, "full volume reason")
        }
        try expect(FileManager.default.fileExists(atPath: large.path), "failed move keeps the source")
        try expect(!FileManager.default.fileExists(atPath: landed.path), "failed move leaves no destination")
        #endif
    }

    #if os(macOS)
    private static func acrossVolumesTool(
        _ executable: String,
        _ arguments: [String]
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    #endif
}
