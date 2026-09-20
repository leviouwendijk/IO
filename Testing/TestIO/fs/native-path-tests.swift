import Foundation
import IO

extension TestIO {
    static func testNativePathSubstrate() throws {
        guard let parent = NativePath(
            fileSystemBytes: Array(
                "/tmp/native-path-root".utf8
            )
        ) else {
            throw TestFailure(
                message: "valid native parent path rejected"
            )
        }

        guard let component = NativePath.Component(
            fileSystemBytes: Array(
                "føø-犬.txt".utf8
            )
        ) else {
            throw TestFailure(
                message: "valid native path component rejected"
            )
        }

        let child = parent.appending(component)

        try expectEqual(
            Array(child.fileSystemBytes),
            Array(
                "/tmp/native-path-root/føø-犬.txt".utf8
            ),
            "native path append bytes"
        )
        try expectEqual(
            child.isAbsolute,
            true,
            "native absolute path"
        )
        try expectEqual(
            child.fileSystemURL(
                isDirectory: false
            ).standardizedFileURL.path,
            "/tmp/native-path-root/føø-犬.txt",
            "native path URL conversion"
        )

        guard NativePath.Component(
            fileSystemBytes: []
        ) == nil else {
            throw TestFailure(
                message: "empty native component must be rejected"
            )
        }
        guard NativePath.Component(
            fileSystemBytes: Array(
                "a/b".utf8
            )
        ) == nil else {
            throw TestFailure(
                message: "slash-containing native component must be rejected"
            )
        }
        guard NativePath(
            fileSystemBytes: [
                47,
                116,
                109,
                112,
                0,
                120,
            ]
        ) == nil else {
            throw TestFailure(
                message: "embedded NUL native path must be rejected"
            )
        }

        let opaqueBytes: [UInt8] = [
            47,
            116,
            109,
            112,
            47,
            0x80,
            0xFF,
        ]
        guard let opaque = NativePath(
            fileSystemBytes: opaqueBytes
        ) else {
            throw TestFailure(
                message: "opaque native path bytes rejected"
            )
        }

        var observedOpaqueBytes: [UInt8] = []
        opaque.withCString { pointer in
            var index = 0

            while pointer[index] != 0 {
                observedOpaqueBytes.append(
                    UInt8(
                        bitPattern: pointer[index]
                    )
                )
                index += 1
            }
        }

        try expectEqual(
            observedOpaqueBytes,
            opaqueBytes,
            "native path preserves opaque bytes"
        )

        let sourceURL = URL(
            fileURLWithPath:
                "/tmp/native path/føø-犬",
            isDirectory: true
        ).standardizedFileURL

        guard let roundTripPath = NativePath(
            fileSystemURL: sourceURL
        ) else {
            throw TestFailure(
                message: "file URL could not form NativePath"
            )
        }

        try expectEqual(
            roundTripPath.fileSystemURL(
                isDirectory: true
            ).standardizedFileURL,
            sourceURL,
            "native path URL round trip"
        )

        var builder = NativeDirectoryEntries.Builder(
            parent: parent
        )

        let firstBytes = Array(
            "one.txt".utf8
        )
        firstBytes.withUnsafeBufferPointer {
            builder.appendTrustedFileSystemComponent(
                $0,
                kind: .file,
                isDirectoryPath: false
            )
        }

        let secondBytes = Array(
            "subdir".utf8
        )
        secondBytes.withUnsafeBufferPointer {
            builder.appendTrustedFileSystemComponent(
                $0,
                kind: .directory,
                isDirectoryPath: true
            )
        }

        let batch = builder.build()

        try expectEqual(
            batch.count,
            2,
            "native directory entry count"
        )

        let first = batch.entries[0]
        let second = batch.entries[1]

        try expectEqual(
            Array(
                batch.componentBytes(
                    for: first
                )
            ),
            firstBytes,
            "native directory first component"
        )
        try expectEqual(
            Array(
                batch.path(
                    for: second
                ).fileSystemBytes
            ),
            Array(
                "/tmp/native-path-root/subdir".utf8
            ),
            "native directory shared parent path"
        )
        try expectEqual(
            second.isDirectoryPath,
            true,
            "native directory path semantic bit"
        )
    }
}
