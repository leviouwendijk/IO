/// Shared storage for one native directory enumeration.
///
/// The parent path is stored once. Child names are packed contiguously and
/// entries retain only their component range plus filesystem metadata needed at
/// the compatibility boundary.
package struct NativeDirectoryEntries: Sendable {
    package struct Entry: Sendable, Hashable {
        package let componentRange: Range<Int>
        package let kind: FileKind
        package let isDirectoryPath: Bool
    }

    package struct Builder {
        private let parent: NativePath
        private var componentStorage: [UInt8]
        private var entries: [Entry]

        package init(
            parent: NativePath,
            estimatedEntryCount: Int = 0,
            estimatedComponentBytes: Int = 0
        ) {
            self.parent = parent
            self.componentStorage = []
            self.entries = []

            if estimatedEntryCount > 0 {
                self.entries.reserveCapacity(
                    estimatedEntryCount
                )
            }

            if estimatedComponentBytes > 0 {
                self.componentStorage.reserveCapacity(
                    estimatedComponentBytes
                )
            }
        }

        /// Appends a component supplied directly by a directory-entry record.
        ///
        /// `readdir` guarantees that the component is a single NUL-terminated
        /// filename rather than a slash-separated path. Dot entries are filtered
        /// by the caller before reaching this trusted boundary.
        package mutating func appendTrustedFileSystemComponent(
            _ component: UnsafeBufferPointer<UInt8>,
            kind: FileKind,
            isDirectoryPath: Bool
        ) {
            let lowerBound = componentStorage.count
            componentStorage.append(
                contentsOf: component
            )

            entries.append(
                .init(
                    componentRange:
                        lowerBound..<componentStorage.count,
                    kind: kind,
                    isDirectoryPath: isDirectoryPath
                )
            )
        }

        package func build() -> NativeDirectoryEntries {
            .init(
                parent: parent,
                componentStorage: componentStorage,
                entries: entries
            )
        }
    }

    package let parent: NativePath
    private let componentStorage: [UInt8]
    package let entries: [Entry]

    private init(
        parent: NativePath,
        componentStorage: [UInt8],
        entries: [Entry]
    ) {
        self.parent = parent
        self.componentStorage = componentStorage
        self.entries = entries
    }

    package var count: Int {
        entries.count
    }

    package func componentBytes(
        for entry: Entry
    ) -> ArraySlice<UInt8> {
        componentStorage[
            entry.componentRange
        ]
    }

    package func path(
        for entry: Entry
    ) -> NativePath {
        parent.appendingTrustedFileSystemComponent(
            componentBytes(for: entry)
        )
    }

    package func materializedFileSystemEntries()
        -> [FileSystemEntry]
    {
        var result: [FileSystemEntry] = []
        result.reserveCapacity(entries.count)

        appendMaterializedFileSystemEntries(
            to: &result
        )

        return result
    }

    package func appendMaterializedFileSystemEntries(
        to result: inout [FileSystemEntry]
    ) {
        for entry in entries {
            let path = path(for: entry)

            result.append(
                .init(
                    standardizedURL: path.fileSystemURL(
                        isDirectory: entry.isDirectoryPath
                    ),
                    kind: entry.kind
                )
            )
        }
    }
}
