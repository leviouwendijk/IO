import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    struct FileSystemFixture {
        let root: URL
        let regularFile: URL
        let emptyDirectory: URL
        let nestedDirectory: URL
        let nestedFile: URL
        let fileSymlink: URL
        let directorySymlink: URL
        let brokenSymlink: URL
        let fifo: URL
        let missing: URL
        let wideDirectory: URL
        let deepRoot: URL
        let deepestDirectory: URL
    }

    struct FileSystemBenchmarkFixture {
        let root: URL
        let flatSmall: URL
        let flatWide1K: URL
        let flatWide10K: URL?
        let emptyDirectory: URL
        let deepNarrow: URL
        let mixedTree: URL
    }

    static func withFileSystemFixture<Result>(
        wideCount: Int = 64,
        deepDepth: Int = 8,
        _ body: (FileSystemFixture) throws -> Result
    ) throws -> Result {
        let manager = FileManager.default
        let root = temporaryFileSystemRoot(
            prefix: "io-fs-semantics"
        )

        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        defer {
            try? manager.removeItem(
                at: root
            )
        }

        let regularFile = root.appendingPathComponent(
            "regular.txt"
        )
        try writeFixtureFile(
            regularFile,
            contents: "root\n"
        )

        let emptyDirectory = root.appendingPathComponent(
            "empty",
            isDirectory: true
        )
        try manager.createDirectory(
            at: emptyDirectory,
            withIntermediateDirectories: false
        )

        let nestedDirectory = root.appendingPathComponent(
            "nested",
            isDirectory: true
        )
        try manager.createDirectory(
            at: nestedDirectory,
            withIntermediateDirectories: false
        )

        let nestedFile = nestedDirectory.appendingPathComponent(
            "child.txt"
        )
        try writeFixtureFile(
            nestedFile,
            contents: "child\n"
        )

        let fileSymlink = root.appendingPathComponent(
            "file-link"
        )
        try manager.createSymbolicLink(
            at: fileSymlink,
            withDestinationURL: regularFile
        )

        let directorySymlink = root.appendingPathComponent(
            "directory-link"
        )
        try manager.createSymbolicLink(
            at: directorySymlink,
            withDestinationURL: nestedDirectory
        )

        let missing = root.appendingPathComponent(
            "missing"
        )

        let brokenSymlink = root.appendingPathComponent(
            "broken-link"
        )
        try manager.createSymbolicLink(
            at: brokenSymlink,
            withDestinationURL: missing
        )

        let fifo = root.appendingPathComponent(
            "fifo"
        )
        let fifoResult = fifo.path.withCString {
            mkfifo(
                $0,
                mode_t(0o600)
            )
        }

        guard fifoResult == 0 else {
            throw TestFailure(
                message: "mkfifo failed with errno \(errno)"
            )
        }

        let wideDirectory = root.appendingPathComponent(
            "wide",
            isDirectory: true
        )
        try makeFlatDirectory(
            wideDirectory,
            count: wideCount
        )

        let deepRoot = root.appendingPathComponent(
            "deep",
            isDirectory: true
        )
        let deepestDirectory = try makeDeepDirectory(
            deepRoot,
            depth: deepDepth
        )

        return try body(
            .init(
                root: root,
                regularFile: regularFile,
                emptyDirectory: emptyDirectory,
                nestedDirectory: nestedDirectory,
                nestedFile: nestedFile,
                fileSymlink: fileSymlink,
                directorySymlink: directorySymlink,
                brokenSymlink: brokenSymlink,
                fifo: fifo,
                missing: missing,
                wideDirectory: wideDirectory,
                deepRoot: deepRoot,
                deepestDirectory: deepestDirectory
            )
        )
    }

    static func withFileSystemBenchmarkFixture<Result>(
        heavy: Bool,
        _ body: (FileSystemBenchmarkFixture) throws -> Result
    ) throws -> Result {
        let manager = FileManager.default
        let root = temporaryFileSystemRoot(
            prefix: "io-fs-baseline"
        )

        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        defer {
            try? manager.removeItem(
                at: root
            )
        }

        let flatSmall = root.appendingPathComponent(
            "flat-small",
            isDirectory: true
        )
        try makeFlatDirectory(
            flatSmall,
            count: 64
        )

        let flatWide1K = root.appendingPathComponent(
            "flat-wide-1k",
            isDirectory: true
        )
        try makeFlatDirectory(
            flatWide1K,
            count: 1_000
        )

        let flatWide10K: URL?

        if heavy {
            let directory = root.appendingPathComponent(
                "flat-wide-10k",
                isDirectory: true
            )
            try makeFlatDirectory(
                directory,
                count: 10_000
            )
            flatWide10K = directory
        } else {
            flatWide10K = nil
        }

        let emptyDirectory = root.appendingPathComponent(
            "empty",
            isDirectory: true
        )
        try manager.createDirectory(
            at: emptyDirectory,
            withIntermediateDirectories: false
        )

        let deepNarrow = root.appendingPathComponent(
            "deep-narrow",
            isDirectory: true
        )
        _ = try makeDeepDirectory(
            deepNarrow,
            depth: heavy ? 128 : 64
        )

        let mixedTree = root.appendingPathComponent(
            "mixed-tree",
            isDirectory: true
        )
        try makeMixedTree(
            mixedTree,
            branchCount: heavy ? 64 : 16,
            filesPerBranch: heavy ? 32 : 12
        )

        return try body(
            .init(
                root: root,
                flatSmall: flatSmall,
                flatWide1K: flatWide1K,
                flatWide10K: flatWide10K,
                emptyDirectory: emptyDirectory,
                deepNarrow: deepNarrow,
                mixedTree: mixedTree
            )
        )
    }

    static func makeFlatDirectory(
        _ directory: URL,
        count: Int
    ) throws {
        let manager = FileManager.default

        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        for index in 0..<count {
            let file = directory.appendingPathComponent(
                String(
                    format: "entry-%05d.txt",
                    index
                )
            )

            try writeFixtureFile(
                file,
                contents: "\(index)\n"
            )
        }
    }

    @discardableResult
    static func makeDeepDirectory(
        _ root: URL,
        depth: Int
    ) throws -> URL {
        let manager = FileManager.default

        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        var current = root

        for level in 0..<depth {
            let directory = current.appendingPathComponent(
                String(
                    format: "d%03d",
                    level
                ),
                isDirectory: true
            )

            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )

            try writeFixtureFile(
                directory.appendingPathComponent(
                    "payload.txt"
                ),
                contents: "\(level)\n"
            )

            current = directory
        }

        return current
    }

    static func makeMixedTree(
        _ root: URL,
        branchCount: Int,
        filesPerBranch: Int
    ) throws {
        let manager = FileManager.default

        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        for branch in 0..<branchCount {
            let branchDirectory = root.appendingPathComponent(
                String(
                    format: "branch-%04d",
                    branch
                ),
                isDirectory: true
            )

            try manager.createDirectory(
                at: branchDirectory,
                withIntermediateDirectories: false
            )

            for fileIndex in 0..<filesPerBranch {
                try writeFixtureFile(
                    branchDirectory.appendingPathComponent(
                        String(
                            format: "entry-%04d.txt",
                            fileIndex
                        )
                    ),
                    contents: "\(branch)-\(fileIndex)\n"
                )
            }

            let leafDirectory = branchDirectory.appendingPathComponent(
                "leaf",
                isDirectory: true
            )

            try manager.createDirectory(
                at: leafDirectory,
                withIntermediateDirectories: false
            )

            for fileIndex in 0..<max(1, filesPerBranch / 4) {
                try writeFixtureFile(
                    leafDirectory.appendingPathComponent(
                        String(
                            format: "leaf-%04d.txt",
                            fileIndex
                        )
                    ),
                    contents: "\(fileIndex)\n"
                )
            }
        }
    }

    static func writeFixtureFile(
        _ url: URL,
        contents: String
    ) throws {
        try Data(
            contents.utf8
        ).write(
            to: url
        )
    }

    static func temporaryFileSystemRoot(
        prefix: String
    ) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(prefix)-\(UUID().uuidString)",
                isDirectory: true
            )
    }
}