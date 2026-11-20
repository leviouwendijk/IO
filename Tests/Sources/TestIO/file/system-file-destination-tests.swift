import IO
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    static func testSystemFileDestinationModes() throws {
        try testSystemFileDestinationCreateMode()
        try testSystemFileDestinationTruncateMode()
        try testSystemFileDestinationAppendMode()
    }

    static func testSystemFileDestinationWithDestination() throws {
        let url = temporaryURL(
            name: "system-file-destination-integration"
        )
        defer {
            try? FileManager.default.removeItem(
                at: url
            )
        }

        var destination = Destination(
            try SystemFileDestination(
                path: url.path,
                mode: .truncate
            ),
            bufferCapacity:
                try BufferCapacity(
                    4
                )
        )

        try expectEqual(
            try destination.write(
                [1, 2, 3]
            ),
            .complete,
            "tiny file destination write"
        )
        try expectEqual(
            destination.bufferedByteCount,
            3,
            "tiny file destination bytes remain staged"
        )

        try expectEqual(
            try destination.flush(),
            .complete,
            "file destination logical flush"
        )
        try expectEqual(
            Array(
                try Data(
                    contentsOf: url
                )
            ),
            [1, 2, 3],
            "file destination flushed staged bytes"
        )

        let large = Array(
            4...15
        ).map(
            UInt8.init
        )

        try expectEqual(
            try destination.write(
                large
            ),
            .complete,
            "large file destination write"
        )
        try expectEqual(
            try destination.flush(),
            .complete,
            "large file destination flush"
        )
        try expectEqual(
            Array(
                try Data(
                    contentsOf: url
                )
            ),
            [1, 2, 3] + large,
            "file destination direct bypass bytes"
        )
    }

    static func testSystemFileDestinationVectorDrain() throws {
        let url = temporaryURL(
            name: "system-file-destination-vector"
        )
        defer {
            try? FileManager.default.removeItem(
                at: url
            )
        }

        var backend =
            try SystemFileDestination(
                path: url.path,
                mode: .truncate
            )

        let first: [UInt8] = [
            10, 11, 12,
        ]
        let second: [UInt8] = [
            13, 14, 15, 16,
        ]

        let result =
            try first.withUnsafeBytes {
                firstBytes in

                try second.withUnsafeBytes {
                    secondBytes in

                    try backend.drain(
                        first: firstBytes,
                        second: secondBytes
                    )
                }
            }

        switch result {
        case .bytes(let count):
            try expectEqual(
                count.value,
                first.count
                    + second.count,
                "vector file drain byte count"
            )

        case .unavailable:
            throw TestFailure(
                message:
                    "regular file vector drain unexpectedly unavailable"
            )
        }

        try backend.close()

        try expectEqual(
            Array(
                try Data(
                    contentsOf: url
                )
            ),
            first + second,
            "writev preserves logical region order"
        )
    }

    static func testSystemFileDestinationDescriptorLifecycle() throws {
        let url = temporaryURL(
            name: "system-file-destination-lifecycle"
        )
        defer {
            try? FileManager.default.removeItem(
                at: url
            )
        }

        let before =
            try systemDestinationOpenDescriptorCount()

        for value in 0..<2_000 {
            var backend =
                try SystemFileDestination(
                    path: url.path,
                    mode: .truncate
                )
            let byte = UInt8(
                truncatingIfNeeded: value
            )

            _ = try withUnsafeBytes(
                of: byte
            ) {
                try backend.drain(
                    $0
                )
            }
        }

        let after =
            try systemDestinationOpenDescriptorCount()

        guard after <= before + 1 else {
            throw TestFailure(
                message:
                    "SystemFileDestination leaked descriptors: "
                    + "before=\(before) "
                    + "after=\(after)"
            )
        }
    }

    static func testSystemFileDestinationExplicitCloseIsIdempotent() throws {
        let url = temporaryURL(
            name: "system-file-destination-explicit-close"
        )
        defer {
            try? FileManager.default.removeItem(
                at: url
            )
        }

        let sentinel =
            try closeDestinationThenOpenSentinel(
                path: url.path
            )
        defer {
            _ = systemDestinationTestClose(
                sentinel
            )
        }

        guard systemDestinationDescriptorIsOpen(
            sentinel
        ) else {
            throw TestFailure(
                message:
                    "SystemFileDestination deinit double-closed a reused descriptor"
            )
        }
    }

    static func testSystemFileDestinationClosedError() throws {
        let url = temporaryURL(
            name: "system-file-destination-closed"
        )
        defer {
            try? FileManager.default.removeItem(
                at: url
            )
        }

        var backend =
            try SystemFileDestination(
                path: url.path,
                mode: .truncate
            )

        try backend.close()
        try backend.close()

        let byte = UInt8(1)

        do {
            _ = try withUnsafeBytes(
                of: byte
            ) {
                try backend.drain(
                    $0
                )
            }

            throw TestFailure(
                message:
                    "closed SystemFileDestination accepted bytes"
            )
        } catch let error as SystemFileDestinationError {
            try expectEqual(
                error,
                .closed(
                    path: url.path
                ),
                "closed file destination error"
            )
        }

        do {
            _ = try backend.flush()

            throw TestFailure(
                message:
                    "closed SystemFileDestination flushed"
            )
        } catch let error as SystemFileDestinationError {
            try expectEqual(
                error,
                .closed(
                    path: url.path
                ),
                "closed file destination flush error"
            )
        }
    }

    static func testSystemFileDestinationCreateMode() throws {
        let url = temporaryURL(
            name: "system-file-destination-create"
        )
        defer {
            try? FileManager.default.removeItem(
                at: url
            )
        }

        var backend =
            try SystemFileDestination(
                path: url.path,
                mode: .create
            )

        let payload = Array(
            "created".utf8
        )

        _ = try payload.withUnsafeBytes {
            try backend.drain(
                $0
            )
        }
        try backend.close()

        try expectEqual(
            Array(
                try Data(
                    contentsOf: url
                )
            ),
            payload,
            "create mode payload"
        )

        do {
            var duplicate =
                try SystemFileDestination(
                    path: url.path,
                    mode: .create
                )
            try duplicate.close()

            throw TestFailure(
                message:
                    "create mode replaced an existing file"
            )
        } catch let error as SystemFileDestinationError {
            try expectEqual(
                error,
                .open(
                    path: url.path,
                    code: EEXIST
                ),
                "create mode existing-path error"
            )
        }
    }

    static func testSystemFileDestinationTruncateMode() throws {
        let url = temporaryURL(
            name: "system-file-destination-truncate"
        )
        defer {
            try? FileManager.default.removeItem(
                at: url
            )
        }

        try Data(
            "old-long-payload".utf8
        ).write(
            to: url
        )

        var backend =
            try SystemFileDestination(
                path: url.path,
                mode: .truncate
            )
        let replacement =
            Array(
                "new".utf8
            )

        _ = try replacement.withUnsafeBytes {
            try backend.drain(
                $0
            )
        }
        try backend.close()

        try expectEqual(
            Array(
                try Data(
                    contentsOf: url
                )
            ),
            replacement,
            "truncate mode removes previous suffix"
        )
    }

    static func testSystemFileDestinationAppendMode() throws {
        let url = temporaryURL(
            name: "system-file-destination-append"
        )
        defer {
            try? FileManager.default.removeItem(
                at: url
            )
        }

        let prefix =
            Array(
                "head".utf8
            )
        let suffix =
            Array(
                "-tail".utf8
            )

        try Data(
            prefix
        ).write(
            to: url
        )

        var backend =
            try SystemFileDestination(
                path: url.path,
                mode: .append
            )

        _ = try suffix.withUnsafeBytes {
            try backend.drain(
                $0
            )
        }
        try backend.close()

        try expectEqual(
            Array(
                try Data(
                    contentsOf: url
                )
            ),
            prefix + suffix,
            "append mode preserves existing prefix"
        )
    }

    static func systemDestinationOpenDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(
            atPath: "/dev/fd"
        ).count
    }

    static func closeDestinationThenOpenSentinel(
        path: String
    ) throws -> Int32 {
        var backend =
            try SystemFileDestination(
                path: path,
                mode: .truncate
            )

        try backend.close()
        try backend.close()

        let sentinel =
            path.withCString {
                systemDestinationTestOpen(
                    $0
                )
            }

        guard sentinel >= 0 else {
            throw TestFailure(
                message:
                    "could not open destination sentinel descriptor"
            )
        }

        return sentinel
    }
}

@inline(__always)
func systemDestinationTestOpen(
    _ path: UnsafePointer<CChar>
) -> Int32 {
    #if canImport(Darwin)
    Darwin.open(
        path,
        O_WRONLY
    )
    #elseif canImport(Glibc)
    Glibc.open(
        path,
        O_WRONLY
    )
    #endif
}

@inline(__always)
func systemDestinationTestClose(
    _ descriptor: Int32
) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(
        descriptor
    )
    #elseif canImport(Glibc)
    Glibc.close(
        descriptor
    )
    #endif
}

@inline(__always)
func systemDestinationDescriptorIsOpen(
    _ descriptor: Int32
) -> Bool {
    #if canImport(Darwin)
    Darwin.fcntl(
        descriptor,
        F_GETFD
    ) != -1
    #elseif canImport(Glibc)
    Glibc.fcntl(
        descriptor,
        F_GETFD
    ) != -1
    #endif
}
