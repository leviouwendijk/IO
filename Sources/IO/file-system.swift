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
    }
}
