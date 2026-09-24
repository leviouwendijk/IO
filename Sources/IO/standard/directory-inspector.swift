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
        let entries: [FileSystemEntry]

        do {
            entries = try fileSystem.directory.entries(
                url
            )
        } catch let error as FileSystemError {
            throw error
        } catch {
            throw DirectoryInspectionError.io(
                url,
                message: error.localizedDescription
            )
        }

        return try entries
            .sorted {
                $0.url.path < $1.url.path
            }
            .map {
                try FileInspector(
                    $0.url,
                    fileSystem: fileSystem
                ).inspect()
            }
    }
}
