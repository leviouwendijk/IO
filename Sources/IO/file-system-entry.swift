import Foundation

public struct FileSystemEntry:
    Sendable,
    Hashable
{
    public let url: URL
    public let kind: FileKind

    public init(
        url: URL,
        kind: FileKind
    ) {
        self.url =
            url.standardizedFileURL

        self.kind =
            kind
    }
}
