import Foundation

/// Filesystem-native path storage.
///
/// The stored representation is the exact NUL-terminated byte sequence used at
/// the POSIX boundary. No lexical normalization or URL parsing occurs here.
package struct NativePath: Sendable, Hashable {
    package struct Component: Sendable, Hashable {
        fileprivate let storage: [UInt8]

        package init?(
            fileSystemBytes: [UInt8]
        ) {
            guard !fileSystemBytes.isEmpty,
                  !fileSystemBytes.contains(0),
                  !fileSystemBytes.contains(47)
            else {
                return nil
            }

            self.storage = fileSystemBytes
        }

        package var fileSystemBytes: [UInt8] {
            storage
        }
    }

    /// NUL-terminated filesystem representation.
    private let storage: [UInt8]

    package init?(
        fileSystemBytes: [UInt8]
    ) {
        guard !fileSystemBytes.contains(0) else {
            return nil
        }

        var storage = fileSystemBytes
        storage.append(0)
        self.storage = storage
    }

    package init?(
        fileSystemURL url: URL
    ) {
        guard url.isFileURL else {
            return nil
        }

        guard let storage = url.standardizedFileURL
            .withUnsafeFileSystemRepresentation({ pointer -> [UInt8]? in
                guard let pointer else {
                    return nil
                }

                var count = 0
                while pointer[count] != 0 {
                    count += 1
                }

                return pointer.withMemoryRebound(
                    to: UInt8.self,
                    capacity: count + 1
                ) {
                    Array(
                        UnsafeBufferPointer(
                            start: $0,
                            count: count + 1
                        )
                    )
                }
            })
        else {
            return nil
        }

        self.storage = storage
    }

    private init(
        validatedStorage storage: [UInt8]
    ) {
        self.storage = storage
    }

    package var fileSystemBytes: ArraySlice<UInt8> {
        storage.dropLast()
    }

    package var isAbsolute: Bool {
        storage.first == 47
    }

    package func appending(
        _ component: Component
    ) -> NativePath {
        appendingTrustedFileSystemComponent(
            component.storage[...]
        )
    }

    func appendingTrustedFileSystemComponent(
        _ component: ArraySlice<UInt8>
    ) -> NativePath {
        let parentCount = storage.count - 1
        let needsSeparator =
            parentCount > 0
            && storage[parentCount - 1] != 47

        var result: [UInt8] = []
        result.reserveCapacity(
            parentCount
                + (needsSeparator ? 1 : 0)
                + component.count
                + 1
        )
        result.append(
            contentsOf: storage[..<parentCount]
        )

        if needsSeparator {
            result.append(47)
        }

        result.append(contentsOf: component)
        result.append(0)

        return .init(
            validatedStorage: result
        )
    }

    package func withCString<Result>(
        _ body: (UnsafePointer<CChar>) throws -> Result
    ) rethrows -> Result {
        try storage.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                preconditionFailure(
                    "NativePath storage must contain its NUL terminator."
                )
            }

            return try baseAddress.withMemoryRebound(
                to: CChar.self,
                capacity: buffer.count
            ) {
                try body($0)
            }
        }
    }

    package func fileSystemURL(
        isDirectory: Bool
    ) -> URL {
        withCString {
            URL(
                fileURLWithFileSystemRepresentation: $0,
                isDirectory: isDirectory,
                relativeTo: nil
            )
        }
    }
}
