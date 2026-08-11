import Foundation

public struct DirectoryInspector: Sendable {
    public let url: URL
    public let fileSystem: FileSystem

    public init(
        _ url: URL,
        fileSystem: FileSystem = .default
    ) {
        self.url = url.standardizedFileURL
        self.fileSystem = fileSystem
    }

    public func entries() throws -> [FileMetadataSnapshot] {
        let urls: [URL]

        do {
            urls = try fileSystem.directory.contents(
                url
            )
        } catch {
            throw DirectoryInspectionError.io(
                url,
                message: error.localizedDescription
            )
        }

        return try urls
            .sorted {
                $0.path < $1.path
            }
            .map {
                try FileInspector(
                    $0
                ).inspect()
            }
    }
}
