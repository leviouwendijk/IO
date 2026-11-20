import Foundation
import IO

extension TestIO {
    static func testFileSystemSpace() throws {
        let root = temporaryURL(
            name: "filesystem-space"
        )
        try FileSystem.default.directory.create(root)
        defer { try? FileSystem.default.remove(root) }

        let volume = try FileSystem.default.volume(of: root)
        try expect(volume.total > 0, "volume total is positive")
        try expect(volume.available > 0 && volume.available <= volume.total, "available within total")

        let empty = try FileSystem.default.size(of: root)

        let nested = root.appendingPathComponent("a/b", isDirectory: true)
        try FileSystem.default.directory.create(nested)
        let file = nested.appendingPathComponent("data.bin")
        try Data(repeating: 7, count: 100_000).write(to: file)
        let withFile = try FileSystem.default.size(of: root)
        try expect(withFile - empty >= 100_000, "a 100 kB file adds at least 100 kB allocated")

        let link = root.appendingPathComponent("hard.bin")
        guard link.withUnsafeFileSystemRepresentation({ l in
            file.withUnsafeFileSystemRepresentation { f in Foundation.link(f!, l!) }
        }) == 0 else {
            throw TestFailure(message: "hard link fixture failed")
        }
        let withLink = try FileSystem.default.size(of: root)
        try expect(withLink - withFile < 4096, "a hard link to a counted inode is not counted again")

        try expectEqual(
            try FileSystem.default.size(of: file),
            try FileSystem.default.size(of: link),
            "a single file sizes the same through either link"
        )

        try expectEqual(
            try FileSystem.cwd().standardizedFileURL.path,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path,
            "cwd is getcwd"
        )

        do {
            _ = try FileSystem.default.size(of: root.appendingPathComponent("missing"))
            throw TestFailure(message: "allocated size of a missing path must fail")
        } catch let error as FileSystemError {
            try expectEqual(error.reason, .not_found, "missing root reason")
        }
    }
}
