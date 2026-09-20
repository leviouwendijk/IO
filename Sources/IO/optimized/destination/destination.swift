/// Buffered, runtime-polymorphic consumer of bytes.
///
/// `Destination` uses ring-backed staging storage so short downstream progress never
/// requires relocating an unread suffix. The runtime-selected backend is crossed only
/// when bytes must drain or a logical flush is requested.
public struct Destination: ~Copyable {
    private var backend: any DestinationBackend & ~Copyable
    private var buffer: StreamRingBuffer
    private var drainCallCount: UInt64
    private var drainedByteCount: UInt64
    private var flushCallCount: UInt64
    private var splitDrainCallCount: UInt64
    private var directDrainCallCount: UInt64
    private let directBypassPolicy: DestinationDirectBypassPolicy

    public init<Backend: DestinationBackend & ~Copyable>(
        _ backend: consuming Backend,
        bufferCapacity: BufferCapacity = .default
    ) {
        self.backend = consume backend
        self.buffer = StreamRingBuffer(capacity: bufferCapacity)
        self.drainCallCount = 0
        self.drainedByteCount = 0
        self.flushCallCount = 0
        self.splitDrainCallCount = 0
        self.directDrainCallCount = 0
        self.directBypassPolicy = .larger_than_buffer
    }

    package init<Backend: DestinationBackend & ~Copyable>(
        _ backend: consuming Backend,
        bufferCapacity: BufferCapacity,
        directBypassPolicy: DestinationDirectBypassPolicy
    ) {
        self.backend = consume backend
        self.buffer = StreamRingBuffer(capacity: bufferCapacity)
        self.drainCallCount = 0
        self.drainedByteCount = 0
        self.flushCallCount = 0
        self.splitDrainCallCount = 0
        self.directDrainCallCount = 0
        self.directBypassPolicy = directBypassPolicy
    }

    public var bufferedByteCount: Int {
        borrowing get { buffer.readableCount }
    }

    public var statistics: DestinationStatistics {
        borrowing get {
            .init(
                drainCallCount: drainCallCount,
                drainedByteCount: drainedByteCount,
                flushCallCount: flushCallCount
            )
        }
    }

    /// Diagnostic count of drains that exposed two physical readable regions.
    package var splitDrainCount: UInt64 {
        borrowing get { splitDrainCallCount }
    }

    package var directDrainCount: UInt64 {
        borrowing get { directDrainCallCount }
    }

    /// Compatibility diagnostic retained for benchmark code. Ring storage never compacts.
    package var bufferCompactionStatistics: StreamBufferCompactionStatistics {
        borrowing get {
            .init(
                callCount: 0,
                movedByteCount: 0
            )
        }
    }

    public mutating func inspectBackend() -> DestinationBackendInspection {
        backend.inspect()
    }

    public mutating func write(
        _ byte: UInt8
    ) throws -> DestinationWrite {
        if buffer.writableCount == 0 {
            switch try drainBufferedOnce() {
            case .bytes:
                break
            case .unavailable:
                return .unavailable
            }
        }

        let appended = buffer.append(byte)
        precondition(appended)
        return .complete
    }

    public mutating func write(
        _ bytes: [UInt8]
    ) throws -> DestinationWrite {
        try bytes.withUnsafeBytes { try write($0) }
    }

    public mutating func write(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationWrite {
        guard !bytes.isEmpty else {
            return .complete
        }

        var accepted = 0

        while accepted < bytes.count {
            let remaining = slice(bytes, from: accepted)

            if buffer.isEmpty
                && directBypassPolicy.shouldBypass(
                    byteCount: remaining.count,
                    bufferCapacity: buffer.capacity
                )
            {
                switch try drainDirect(remaining) {
                case .bytes(let count):
                    accepted += count.value
                    continue
                case .unavailable:
                    return unavailableWrite(after: accepted)
                }
            }

            if buffer.writableCount == 0 {
                switch try drainBufferedOnce() {
                case .bytes:
                    break
                case .unavailable:
                    return unavailableWrite(after: accepted)
                }
            }

            let appended = buffer.append(remaining)
            precondition(appended > 0)
            accepted += appended
        }

        return .complete
    }

    public mutating func flush() throws -> DestinationFlush {
        while !buffer.isEmpty {
            switch try drainBufferedOnce() {
            case .bytes:
                continue
            case .unavailable:
                return .unavailable
            }
        }

        flushCallCount += 1
        return try backend.flush()
    }

    private mutating func drainBufferedOnce() throws -> DestinationDrain {
        let offeredCount = buffer.readableCount
        precondition(offeredCount > 0)

        drainCallCount += 1

        let result = try buffer.withReadableRegions { first, second in
            if !first.isEmpty && !second.isEmpty {
                splitDrainCallCount += 1
            }

            return try backend.drain(
                first: first,
                second: second
            )
        }

        switch result {
        case .bytes(let count):
            try checkDrainCount(
                count,
                offeredCount: offeredCount
            )
            buffer.consume(count.value)
            drainedByteCount += UInt64(count.value)
            return result

        case .unavailable:
            return .unavailable
        }
    }

    private mutating func drainDirect(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        drainCallCount += 1
        directDrainCallCount += 1

        let empty = UnsafeRawBufferPointer(
            start: nil,
            count: 0
        )
        let result = try backend.drain(
            first: bytes,
            second: empty
        )

        switch result {
        case .bytes(let count):
            try checkDrainCount(
                count,
                offeredCount: bytes.count
            )
            drainedByteCount += UInt64(count.value)
            return result

        case .unavailable:
            return .unavailable
        }
    }

    private func checkDrainCount(
        _ count: PositiveByteCount,
        offeredCount: Int
    ) throws {
        guard count.value <= offeredCount else {
            throw StreamContractError.destination_reported_too_many_bytes(
                reported: count.value,
                offered: offeredCount
            )
        }
    }

    private func unavailableWrite(
        after accepted: Int
    ) -> DestinationWrite {
        guard accepted > 0 else {
            return .unavailable
        }

        return .partial(
            .knownPositive(accepted)
        )
    }

    private func slice(
        _ bytes: UnsafeRawBufferPointer,
        from offset: Int
    ) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(
            start: bytes.baseAddress.map {
                $0.advanced(by: offset)
            },
            count: bytes.count - offset
        )
    }
}
