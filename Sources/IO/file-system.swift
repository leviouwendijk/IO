import Foundation

public struct FileSystem: Sendable {
    public static let `default` = Self()

    public init() {}

    public var directory: Directory {
        .init()
    }

    public func exists(
        _ url: URL
    ) -> Bool {
        FileManager.default.fileExists(
            atPath: url.standardizedFileURL.path
        )
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
        public init() {}

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
            try FileManager.default.contentsOfDirectory(
                at: url.standardizedFileURL,
                includingPropertiesForKeys: properties,
                options: options
            )
        }

        public func entries(
            _ url: URL,
            options:
                FileManager.DirectoryEnumerationOptions = []
        ) throws -> [FileSystemEntry] {
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

            return try urls.compactMap {
                child in

                let values: URLResourceValues

                do {
                    values =
                        try child.resourceValues(
                            forKeys: keys
                        )
                } catch {
                    if isMissingFileError(
                        error
                    ) {
                        return nil
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
