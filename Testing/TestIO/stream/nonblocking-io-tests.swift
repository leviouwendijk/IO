import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    static func testByteMatchKernelEquivalence() throws {
        let counts = [1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 257]

        for count in counts {
            var bytes = Array(repeating: UInt8(ascii: "a"), count: count)
            for index in bytes.indices where index % 7 == 3 {
                bytes[index] = 0x0A
            }

            let expected = bytes.withUnsafeBytes { raw in
                collectMatches(raw, kernel: ByteMatch.libc.self)
            }
            let simd16 = bytes.withUnsafeBytes { raw in
                collectMatches(raw, kernel: ByteMatch.simd16.self)
            }
            let simd32 = bytes.withUnsafeBytes { raw in
                collectMatches(raw, kernel: ByteMatch.simd32.self)
            }
            let simd64 = bytes.withUnsafeBytes { raw in
                collectMatches(raw, kernel: ByteMatch.simd64.self)
            }

            try expectEqual(simd16, expected, "SIMD16 matches \(count)")
            try expectEqual(simd32, expected, "SIMD32 matches \(count)")
            try expectEqual(simd64, expected, "SIMD64 matches \(count)")

            if let first = expected.first {
                let stopped = bytes.withUnsafeBytes { raw in
                    ByteMatch.simd32.walk(raw, needle: 0x0A, from: 0) { _ in .stop }
                }
                try expectEqual(stopped, .stopped(at: first), "kernel stop semantics")
            }
        }
    }


    static func testByteLineScannerSwappableKernel() throws {
        let bytes = Array("one\ntwo\nthree\nfour".utf8)
        let expected = try scanKernelSignature(bytes, kernel: ByteMatch.libc.self)
        try expectEqual(
            try scanKernelSignature(bytes, kernel: ByteMatch.simd16.self),
            expected,
            "scanner SIMD16 kernel"
        )
        try expectEqual(
            try scanKernelSignature(bytes, kernel: ByteMatch.simd32.self),
            expected,
            "scanner SIMD32 kernel"
        )
        try expectEqual(
            try scanKernelSignature(bytes, kernel: ByteMatch.simd64.self),
            expected,
            "scanner SIMD64 kernel"
        )
    }

    static func testStreamBufferMemmoveCompaction() throws {
        var buffer = StreamBuffer(capacity: try capacity(8))
        let initial = [UInt8](0..<8)
        let appendedInitial = initial.withUnsafeBytes { buffer.append($0) }
        try expectEqual(appendedInitial, 8, "stream buffer initial append")

        buffer.consume(3)

        let suffix: [UInt8] = [8, 9, 10]
        let appendedSuffix = suffix.withUnsafeBytes { buffer.append($0) }
        try expectEqual(appendedSuffix, 3, "stream buffer append after compaction")

        let logical = buffer.withReadableBytes { Array($0) }
        try expectEqual(
            logical,
            [3, 4, 5, 6, 7, 8, 9, 10],
            "stream buffer overlapping memmove compaction order"
        )
        try expectEqual(buffer.readableCount, 8, "stream buffer readable after compaction")
        try expectEqual(buffer.writableCount, 0, "stream buffer writable after compaction")
        try expectEqual(
            buffer.compactionStatistics,
            .init(callCount: 1, movedByteCount: 5),
            "stream buffer compaction statistics"
        )
    }

    static func testDestinationExactCapacityBypassPolicy() throws {
        let capacity = try capacity(8)
        let bytes = [UInt8](0..<8)

        var staged = Destination(
            MemoryDestination(),
            bufferCapacity: capacity,
            directBypassPolicy: .larger_than_buffer
        )
        try expectEqual(
            try staged.write(bytes),
            .complete,
            "exact-capacity staged write"
        )
        try expectEqual(
            staged.directDrainCount,
            0,
            "exact-capacity default policy stages"
        )

        var direct = Destination(
            MemoryDestination(),
            bufferCapacity: capacity,
            directBypassPolicy: .at_least_buffer
        )
        try expectEqual(
            try direct.write(bytes),
            .complete,
            "exact-capacity direct write"
        )
        try expectEqual(
            direct.directDrainCount,
            1,
            "exact-capacity at-least policy bypasses"
        )
        try expectEqual(
            direct.bufferedByteCount,
            0,
            "exact-capacity direct write leaves staging empty"
        )
    }

    static func testRingBufferWraparound() throws {
        var ring = StreamRingBuffer(capacity: try capacity(8))
        let first = [UInt8](0..<6)
        _ = first.withUnsafeBytes { ring.append($0) }
        ring.consume(5)

        let second: [UInt8] = [10, 11, 12, 13, 14, 15]
        _ = second.withUnsafeBytes { ring.append($0) }

        let logical = ring.withReadableRegions { first, second in
            Array(first) + Array(second)
        }

        try expectEqual(logical, [5, 10, 11, 12, 13, 14, 15], "ring logical order")
        try expectEqual(ring.readableCount, 7, "ring readable count")
        try expectEqual(ring.writableCount, 1, "ring writable count")
    }

    static func testPOSIXVectorIO() throws {
        var descriptors: [Int32] = [0, 0]
        try expect(makeSocketPair(&descriptors) == 0, "socketpair")
        defer {
            closeDescriptor(descriptors[0])
            closeDescriptor(descriptors[1])
        }

        let incoming: [UInt8] = [1, 2, 3, 4, 5, 6]
        _ = incoming.withUnsafeBytes { raw in
            systemSend(descriptors[1], raw)
        }

        var left = Array(repeating: UInt8(0), count: 2)
        var right = Array(repeating: UInt8(0), count: 4)
        let readResult = try left.withUnsafeMutableBytes { first in
            try right.withUnsafeMutableBytes { second in
                try POSIXVectorIO.readv(
                    descriptor: descriptors[0],
                    first: first,
                    second: second
                )
            }
        }
        try expectEqual(readResult, .bytes(6), "readv bytes")
        try expectEqual(left + right, incoming, "readv payload")

        let a: [UInt8] = [7, 8]
        let b: [UInt8] = [9, 10, 11]
        let writeResult = try a.withUnsafeBytes { first in
            try b.withUnsafeBytes { second in
                try POSIXVectorIO.writev(
                    descriptor: descriptors[0],
                    first: first,
                    second: second
                )
            }
        }
        try expectEqual(writeResult, .bytes(5), "writev bytes")
        try expectEqual(systemReceive(descriptors[1], count: 5), a + b, "writev payload")

        let c: [UInt8] = [12, 13, 14]
        let d: [UInt8] = [15, 16]
        let messageResult = try c.withUnsafeBytes { first in
            try d.withUnsafeBytes { second in
                try POSIXVectorIO.sendmsg(
                    descriptor: descriptors[0],
                    first: first,
                    second: second
                )
            }
        }
        try expectEqual(messageResult, .bytes(5), "sendmsg bytes")
        try expectEqual(systemReceive(descriptors[1], count: 5), c + d, "sendmsg payload")
    }

    static func testRingSocketStreams() throws {
        var descriptors: [Int32] = [0, 0]
        try expect(makeSocketPair(&descriptors) == 0, "ring socketpair")
        defer {
            closeDescriptor(descriptors[0])
            closeDescriptor(descriptors[1])
        }

        let sourceBackend = try NonblockingSocketBackend(
            descriptor: descriptors[0],
            ownsDescriptor: false
        )
        var source = RingSource(
            sourceBackend,
            bufferCapacity: try capacity(8)
        )

        let first: [UInt8] = [0, 1, 2, 3, 4, 5]
        _ = first.withUnsafeBytes { systemSend(descriptors[1], $0) }
        try expectEqual(try source.requestMore(), .bytes, "ring socket first refill")
        try source.consume(5)

        let second: [UInt8] = [10, 11, 12, 13, 14, 15]
        _ = second.withUnsafeBytes { systemSend(descriptors[1], $0) }
        try expectEqual(try source.requestMore(), .bytes, "ring socket split refill")

        let logical = source.withReadableRegions { first, second in
            Array(first) + Array(second)
        }
        try expectEqual(
            logical,
            [5, 10, 11, 12, 13, 14, 15],
            "ring socket readv logical order"
        )
        try expectEqual(source.splitRefillCount, 1, "ring socket split refill count")

        let destinationBackend = try NonblockingSocketBackend(
            descriptor: descriptors[0],
            ownsDescriptor: false
        )
        var destination = RingDestination(
            destinationBackend,
            bufferCapacity: try capacity(8)
        )
        let outbound: [UInt8] = [40, 41, 42, 43, 44, 45]
        try expectEqual(
            try destination.write(outbound),
            .complete,
            "ring socket destination write"
        )
        try expectEqual(
            try destination.flush(),
            .complete,
            "ring socket destination flush"
        )
        try expectEqual(
            systemReceive(descriptors[1], count: outbound.count),
            outbound,
            "ring socket destination payload"
        )
    }

    static func testScriptedNonblockingBackpressure() throws {
        var source = Source(
            ScriptedSourceBackend(
                steps: [
                    .unavailable,
                    .retry,
                    .bytes([1, 2, 3]),
                    .unavailable,
                    .bytes([4]),
                    .end,
                ]
            ),
            bufferCapacity: try capacity(8)
        )

        try expectEqual(try source.prepare(), .unavailable, "script source pause")
        try expectEqual(try source.prepare(), .bytes, "script source retry then bytes")
        try expectEqual(bufferedBytes(source), [1, 2, 3], "script source bytes")
        try source.consume(3)
        try expectEqual(try source.prepare(), .unavailable, "script second pause")
        try expectEqual(try source.prepare(), .bytes, "script final bytes")
        try expectEqual(bufferedBytes(source), [4], "script final payload")

        var destination = Destination(
            ScriptedDestinationBackend(
                steps: [
                    .accept(2),
                    .unavailable,
                    .accept(4),
                ]
            ),
            bufferCapacity: try capacity(1)
        )

        let input: [UInt8] = [20, 21, 22, 23, 24, 25]
        let firstWrite = try destination.write(input)
        try expectEqual(firstWrite, .partial(try count(2)), "script destination partial")
        try expectEqual(try destination.write(Array(input.dropFirst(2))), .complete, "script destination resume")
        try expectEqual(destination.inspectBackend().capturedBytes, input, "script destination payload")
    }

    static func testDeterministicReadiness() throws {
        let read = ReadinessToken(rawValue: 1)
        let write = ReadinessToken(rawValue: 2)
        var readiness = DeterministicReadinessBackend()
        try readiness.register(token: read, descriptor: 10, interest: .readable)
        try readiness.register(token: write, descriptor: 11, interest: [.readable, .writable])

        readiness.enqueue(.init(token: write, ready: .writable))
        readiness.enqueue(.init(token: read, ready: [.readable, .writable]))

        try expectEqual(
            try readiness.poll(maximumEvents: 1),
            [.init(token: write, ready: .writable)],
            "readiness first event"
        )
        try expectEqual(
            try readiness.poll(maximumEvents: 4),
            [.init(token: read, ready: .readable)],
            "readiness filtered event"
        )
    }

    static func testNonblockingSocketBackend() throws {
        var descriptors: [Int32] = [0, 0]
        try expect(makeSocketPair(&descriptors) == 0, "nonblocking socketpair")
        defer {
            closeDescriptor(descriptors[0])
            closeDescriptor(descriptors[1])
        }

        let backend = try NonblockingSocketBackend(
            descriptor: descriptors[0],
            ownsDescriptor: false
        )
        var source = Source(backend, bufferCapacity: try capacity(16))
        var destination = Destination(backend, bufferCapacity: try capacity(4))

        try expectEqual(try source.prepare(), .unavailable, "empty nonblocking socket")

        let inbound: [UInt8] = [30, 31, 32]
        _ = inbound.withUnsafeBytes { systemSend(descriptors[1], $0) }
        try expectEqual(try source.prepare(), .bytes, "socket becomes readable")
        try expectEqual(bufferedBytes(source), inbound, "socket source payload")
        try source.consume(inbound.count)

        let outbound: [UInt8] = [40, 41, 42, 43, 44, 45]
        try expectEqual(try destination.write(outbound), .complete, "socket destination")
        try expectEqual(systemReceive(descriptors[1], count: outbound.count), outbound, "socket destination payload")
    }
}

private extension TestIO {

    static func scanKernelSignature<Kernel: ByteMatchKernel>(
        _ bytes: [UInt8],
        kernel: Kernel.Type
    ) throws -> [String] {
        var scanner = ByteLineScanner(
            source: Source(
                MemorySource(bytes: bytes, maximumChunkSize: try count(5)),
                bufferCapacity: try capacity(7)
            )
        )
        var values: [String] = []

        while true {
            let result = try scanner.scan(using: kernel) { fragment in
                values.append(
                    "\(fragment.lineNumber):\(fragment.byteRange.lowerBound)-\(fragment.byteRange.upperBound):\(fragment.ending):\(Array(fragment.bytes))"
                )
                return .continue
            }

            switch result {
            case .end:
                return values
            case .unavailable:
                continue
            case .stopped:
                throw TestFailure(message: "unexpected scanner stop")
            }
        }
    }

    static func collectMatches<Kernel: ByteMatchKernel>(
        _ bytes: UnsafeRawBufferPointer,
        kernel: Kernel.Type
    ) -> [Int] {
        var matches: [Int] = []
        _ = kernel.walk(bytes, needle: 0x0A, from: 0) { index in
            matches.append(index)
            return .continue
        }
        return matches
    }

    static func makeSocketPair(_ descriptors: inout [Int32]) -> Int32 {
        descriptors.withUnsafeMutableBufferPointer { buffer in
            #if canImport(Darwin)
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
            #elseif canImport(Glibc)
            Glibc.socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, buffer.baseAddress)
            #endif
        }
    }

    static func closeDescriptor(_ descriptor: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #elseif canImport(Glibc)
        _ = Glibc.close(descriptor)
        #endif
    }

    static func systemSend(
        _ descriptor: Int32,
        _ bytes: UnsafeRawBufferPointer
    ) -> Int {
        #if canImport(Darwin)
        Darwin.send(descriptor, bytes.baseAddress, bytes.count, 0)
        #elseif canImport(Glibc)
        Glibc.send(descriptor, bytes.baseAddress, bytes.count, Int32(MSG_NOSIGNAL))
        #endif
    }

    static func systemReceive(
        _ descriptor: Int32,
        count: Int
    ) -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: count)
        let received = bytes.withUnsafeMutableBytes { raw -> Int in
            #if canImport(Darwin)
            Darwin.recv(descriptor, raw.baseAddress, raw.count, 0)
            #elseif canImport(Glibc)
            Glibc.recv(descriptor, raw.baseAddress, raw.count, 0)
            #endif
        }
        precondition(received >= 0)
        return Array(bytes.prefix(received))
    }
}
