import Foundation

public struct FileSystem: Sendable {
    enum Implementation: Sendable {
        case foundation
        case c
    }

    /// Foundation-backed implementation retained as an explicit
    /// compatibility and performance-reference path.
    public static let foundation = Self(
        implementation: .foundation
    )

    /// C/POSIX-backed read-side implementation. Metadata,
    /// enumeration, existence, and emptiness probes use native
    /// C/POSIX interfaces; filesystem mutation remains
    /// Foundation-backed for now.
    public static let c = Self(
        implementation: .c
    )

    /// Default implementation selected after semantic-equivalence
    /// and crossover benchmarking against the Foundation reference.
    public static let `default` = c

    let implementation: Implementation

    public init() {
        self.implementation = .c
    }

    private init(
        implementation: Implementation
    ) {
        self.implementation = implementation
    }

    public var directory: Directory {
        .init(
            implementation: implementation
        )
    }

    public func exists(
        _ url: URL
    ) -> Bool {
        switch implementation {
        case .foundation:
            return FileManager.default.fileExists(
                atPath: url.standardizedFileURL.path
            )

        case .c:
            return NativeFileSystem.exists(
                url
            )
        }
    }

    public func copy(
        _ source: URL,
        to destination: URL
    ) throws {
        try FileManager.default.copyItem(
            at: source.standardizedFileURL,
            to: destination.standardizedFileURL
        )
    }

    public func move(
        _ source: URL,
        to destination: URL
    ) throws {
        try FileManager.default.moveItem(
            at: source.standardizedFileURL,
            to: destination.standardizedFileURL
        )
    }

    public func replace(
        _ original: URL,
        with replacement: URL
    ) throws {
        _ = try FileManager.default.replaceItemAt(
            original.standardizedFileURL,
            withItemAt: replacement.standardizedFileURL
        )
    }

    public func remove(
        _ url: URL
    ) throws {
        try FileManager.default.removeItem(
            at: url.standardizedFileURL
        )
    }

    public func resolve(
        _ url: URL
    ) -> URL {
        url
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }
}

public extension FileSystem {
    struct Directory: Sendable {
        let implementation: Implementation

        public init() {
            self.implementation = .c
        }

        fileprivate init(
            implementation: Implementation
        ) {
            self.implementation = implementation
        }

        public func create(
            _ url: URL,
            intermediates: Bool = true,
            attributes: [FileAttributeKey: Any]? = nil
        ) throws {
            try FileManager.default.createDirectory(
                at: url.standardizedFileURL,
                withIntermediateDirectories: intermediates,
                attributes: attributes
            )
        }

        public func contents(
            _ url: URL,
            properties: [URLResourceKey]? = nil,
            options: FileManager.DirectoryEnumerationOptions = []
        ) throws -> [URL] {
            let url = url.standardizedFileURL

            do {
                return try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: properties,
                    options: options
                )
            } catch {
                if let error = FileSystemError.wrapping(
                    error,
                    operation: .enumerate_directory,
                    url: url
                ) {
                    throw error
                }

                throw error
            }
        }

        public func entries(
            _ url: URL,
            recursive: Bool = false,
            options:
                FileManager.DirectoryEnumerationOptions = []
        ) throws -> [FileSystemEntry] {
            switch implementation {
            case .foundation:
                let keys: Set<URLResourceKey> = [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]

                let urls = try contents(
                    url,
                    properties: Array(
                        keys
                    ),
                    options: options
                )

                let direct = try urls.compactMap {
                    child in

                    try entry(
                        for: child,
                        keys: keys
                    )
                }

                guard recursive else {
                    return direct
                }

                var result = direct

                for child in direct
                where child.kind == .directory
                {
                    result.append(
                        contentsOf: try entries(
                            child.url,
                            recursive: true,
                            options: options
                        )
                    )
                }

                return result

            case .c:
                guard recursive else {
                    return try NativeFileSystem.entries(
                        url,
                        options: options
                    )
                }

                return try NativeFileSystem.recursiveEntries(
                    url,
                    options: options
                )
            }
        }

        func isEmpty(
            _ url: URL
        ) throws -> Bool {
            switch implementation {
            case .foundation:
                let url = url.standardizedFileURL

                do {
                    return try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil
                    ).isEmpty
                } catch {
                    if let error = FileSystemError.wrapping(
                        error,
                        operation: .probe_directory_empty,
                        url: url
                    ) {
                        throw error
                    }

                    throw error
                }

            case .c:
                return try NativeFileSystem.isEmpty(
                    url
                )
            }
        }

        private func entry(
            for child: URL,
            keys: Set<URLResourceKey>
        ) throws -> FileSystemEntry? {
            let values: URLResourceValues

            do {
                values = try child.resourceValues(
                    forKeys: keys
                )
            } catch {
                if isMissingFileError(
                    error
                ) {
                    return nil
                }

                if let error = FileSystemError.wrapping(
                    error,
                    operation: .inspect_directory_entry,
                    url: child
                ) {
                    throw error
                }

                throw error
            }

            let kind: FileKind

            if values.isSymbolicLink == true {
                kind = .symlink
            } else if values.isDirectory == true {
                kind = .directory
            } else if values.isRegularFile == true {
                kind = .file
            } else {
                kind = .other
            }

            return .init(
                url: child,
                kind: kind
            )
        }

        private func isMissingFileError(
            _ error: Error
        ) -> Bool {
            let error =
                error as NSError

            guard error.domain
                    == NSCocoaErrorDomain
            else {
                return false
            }

            return error.code
                == CocoaError
                .Code
                .fileNoSuchFile
                .rawValue
                || error.code
                    == CocoaError
                    .Code
                    .fileReadNoSuchFile
                    .rawValue
        }
    }
}
