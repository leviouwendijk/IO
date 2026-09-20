import IO
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    static func testSourceMovePreservesState() throws {
        var source = Source(
            MemorySource(
                bytes: [1, 2, 3, 4, 5],
                maximumChunkSize: try PositiveByteCount(3)
            ),
            bufferCapacity: try BufferCapacity(4)
        )

        guard try source.prepare() == .bytes else {
            throw TestFailure(message: "source move fixture did not prepare")
        }

        try source.consume(1)

        var moved = consume source

        try expectEqual(
            bufferedBytes(moved),
            [2, 3],
            "moved Source preserved unread buffer"
        )

        try expectEqual(
            try moved.requestMore(),
            .bytes,
            "moved Source continued refilling"
        )

        try expectEqual(
            bufferedBytes(moved),
            [2, 3, 4, 5],
            "moved Source preserved backend cursor"
        )

        try expectEqual(
            moved.statistics.refilledByteCount,
            5,
            "moved Source preserved statistics"
        )
    }

    static func testDestinationMovePreservesState() throws {
        var destination = Destination(
            MemoryDestination(),
            bufferCapacity: try BufferCapacity(4)
        )

        _ = try destination.write([1, 2, 3])

        var moved = consume destination

        try expectEqual(
            moved.bufferedByteCount,
            3,
            "moved Destination preserved buffered bytes"
        )

        _ = try moved.write(UInt8(4))
        _ = try moved.flush()

        try expectEqual(
            moved.inspectBackend().capturedBytes,
            [1, 2, 3, 4],
            "moved Destination preserved backend state"
        )
    }

    static func testScannerMovePreservesFragmentState() throws {
        let expected = "A🐕B"
        let bytes = Array((expected + "\n").utf8)

        var scanner = ByteLineScanner(
            source: Source(
                MemorySource(
                    bytes: bytes,
                    maximumChunkSize: try PositiveByteCount(2)
                ),
                bufferCapacity: try BufferCapacity(2)
            )
        )

        var collected: [UInt8] = []
        var stoppedOnce = false

        let first = try scanner.scan { fragment in
            collected.append(contentsOf: fragment.bytes)

            if !stoppedOnce,
               fragment.ending == .none
            {
                stoppedOnce = true
                return .stop
            }

            return .continue
        }

        try expectEqual(
            first,
            .stopped,
            "scanner should stop mid-line before ownership move"
        )

        var moved = consume scanner

        let second = try moved.scan { fragment in
            collected.append(contentsOf: fragment.bytes)
            return .continue
        }

        try expectEqual(second, .end, "moved scanner should reach EOF")
        try expectEqual(
            String(decoding: collected, as: UTF8.self),
            expected,
            "scanner move split a UTF-8 scalar or changed bytes"
        )
        try expectEqual(
            moved.statistics.source.refilledByteCount,
            UInt64(bytes.count),
            "moved scanner preserved Source statistics"
        )
    }

    static func testSystemFileDescriptorLifecycle() throws {
        let url = temporaryURL(name: "descriptor-lifecycle")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("descriptor-lifecycle".utf8).write(to: url)

        let before = try openDescriptorCount()

        for _ in 0..<2_000 {
            var source = Source(
                try SystemFileSource(path: url.path),
                bufferCapacity: try BufferCapacity(16)
            )
            _ = try source.prepare()
        }

        let after = try openDescriptorCount()

        guard after <= before + 1 else {
            throw TestFailure(
                message: "SystemFileSource leaked descriptors: before=\(before) after=\(after)"
            )
        }
    }

    static func testSystemFileExplicitCloseIsIdempotent() throws {
        let url = temporaryURL(name: "explicit-close")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("close-me".utf8).write(to: url)

        let sentinel = try closeSourceThenOpenSentinel(path: url.path)
        defer { _ = ownershipClose(sentinel) }

        guard ownershipDescriptorIsOpen(sentinel) else {
            throw TestFailure(
                message: "SystemFileSource deinit double-closed a reused descriptor"
            )
        }
    }

    private static func openDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(
            atPath: "/dev/fd"
        ).count
    }

    private static func closeSourceThenOpenSentinel(
        path: String
    ) throws -> Int32 {
        var backend = try SystemFileSource(path: path)
        try backend.close()
        try backend.close()

        let sentinel = path.withCString {
            ownershipOpenReadOnly($0)
        }

        guard sentinel >= 0 else {
            throw TestFailure(message: "could not open sentinel descriptor")
        }

        return sentinel
    }
}

@inline(__always)
private func ownershipOpenReadOnly(
    _ path: UnsafePointer<CChar>
) -> Int32 {
    #if canImport(Darwin)
    Darwin.open(path, O_RDONLY)
    #elseif canImport(Glibc)
    Glibc.open(path, O_RDONLY)
    #endif
}

@inline(__always)
private func ownershipClose(
    _ descriptor: Int32
) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(descriptor)
    #elseif canImport(Glibc)
    Glibc.close(descriptor)
    #endif
}

@inline(__always)
private func ownershipDescriptorIsOpen(
    _ descriptor: Int32
) -> Bool {
    #if canImport(Darwin)
    Darwin.fcntl(descriptor, F_GETFD) != -1
    #elseif canImport(Glibc)
    Glibc.fcntl(descriptor, F_GETFD) != -1
    #endif
}
