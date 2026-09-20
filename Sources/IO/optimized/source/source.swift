/// Buffered, runtime-polymorphic producer of bytes.
///
/// `Source` owns ring-backed staging storage and keeps ordinary cursor/borrow mechanics
/// north of the runtime-selected backend boundary. Retained unread bytes are never
/// compacted merely to make room for a refill; the backend may receive two writable
/// physical regions in one logical refill operation.
public struct Source: ~Copyable {
    private var backend: any SourceBackend & ~Copyable
    private var buffer: StreamRingBuffer
    private var ended: Bool
    private var refillCallCount: UInt64
    private var refilledByteCount: UInt64
    private var splitRefillCallCount: UInt64

    public init<Backend: SourceBackend & ~Copyable>(
        _ backend: consuming Backend,
        bufferCapacity: BufferCapacity = .default
    ) {
        self.backend = consume backend
        self.buffer = StreamRingBuffer(capacity: bufferCapacity)
        self.ended = false
        self.refillCallCount = 0
        self.refilledByteCount = 0
        self.splitRefillCallCount = 0
    }

    public var bufferedByteCount: Int {
        borrowing get { buffer.readableCount }
    }

    public var hasReachedEnd: Bool {
        borrowing get { ended }
    }

    public var isExhausted: Bool {
        borrowing get { ended && buffer.isEmpty }
    }

    public var statistics: SourceStatistics {
        borrowing get {
            .init(
                refillCallCount: refillCallCount,
                refilledByteCount: refilledByteCount
            )
        }
    }

    /// Diagnostic count of refill calls that exposed two physical writable regions.
    package var splitRefillCount: UInt64 {
        borrowing get { splitRefillCallCount }
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

    /// Borrows the complete logical readable buffer as at most two physical regions.
    ///
    /// `first` precedes `second` logically. Either region may be empty. Pointers are valid
    /// only for the duration of `body`.
    public borrowing func withReadableRegions<Result>(
        _ body: (UnsafeRawBufferPointer, UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try buffer.withReadableRegions(body)
    }

    /// Borrows the first contiguous readable region.
    ///
    /// Ring-backed storage can wrap, so this region may contain fewer bytes than
    /// `bufferedByteCount`. Algorithms that need the complete logical buffer in one
    /// operation should use `withReadableRegions(_:)`.
    public borrowing func withBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try buffer.withReadableRegions { first, _ in
            try body(first)
        }
    }

    public mutating func consume(
        _ count: Int
    ) throws {
        guard count >= 0 else {
            throw StreamContractError.negative_consume(count)
        }

        guard count <= buffer.readableCount else {
            throw StreamContractError.consume_exceeds_available(
                requested: count,
                available: buffer.readableCount
            )
        }

        buffer.consume(count)
    }

    public mutating func prepare() throws -> SourceAvailability {
        if !buffer.isEmpty {
            return .bytes
        }

        if ended {
            return .end
        }

        return try requestMore()
    }

    /// Appends backend progress behind any unread suffix without relocating it.
    public mutating func requestMore() throws -> SourceAvailability {
        guard !ended else {
            return .end
        }

        guard buffer.writableCount > 0 else {
            return .buffer_full
        }

        let writableCount = buffer.writableCount

        while true {
            refillCallCount += 1

            let refill = try buffer.withWritableRegions { first, second in
                if !first.isEmpty && !second.isEmpty {
                    splitRefillCallCount += 1
                }

                return try backend.refill(
                    first: first,
                    second: second
                )
            }

            switch refill {
            case .bytes(let count):
                try apply(count, writableCount: writableCount)
                return .bytes

            case .final_bytes(let count):
                try apply(count, writableCount: writableCount)
                ended = true
                return .bytes

            case .end:
                ended = true
                return .end

            case .unavailable:
                return .unavailable

            case .retry:
                continue
            }
        }
    }

    /// Copies at most one prepared logical buffer into caller-owned storage.
    public mutating func read(
        into output: UnsafeMutableRawBufferPointer
    ) throws -> SourceRead {
        guard !output.isEmpty else {
            return .empty
        }

        switch try prepare() {
        case .bytes:
            let count = min(output.count, buffer.readableCount)
            var copied = 0

            buffer.withReadableRegions { first, second in
                if copied < count,
                   !first.isEmpty,
                   let destination = output.baseAddress,
                   let source = first.baseAddress
                {
                    let amount = min(first.count, count - copied)
                    destination.copyMemory(
                        from: source,
                        byteCount: amount
                    )
                    copied += amount
                }

                if copied < count,
                   !second.isEmpty,
                   let destination = output.baseAddress,
                   let source = second.baseAddress
                {
                    let amount = min(second.count, count - copied)
                    destination
                        .advanced(by: copied)
                        .copyMemory(
                            from: source,
                            byteCount: amount
                        )
                    copied += amount
                }
            }

            buffer.consume(copied)

            return .bytes(
                .knownPositive(copied)
            )

        case .end:
            return .end
        case .unavailable:
            return .unavailable
        case .buffer_full:
            return .buffer_full
        }
    }

    private mutating func apply(
        _ count: PositiveByteCount,
        writableCount: Int
    ) throws {
        guard count.value <= writableCount else {
            throw StreamContractError.source_reported_too_many_bytes(
                reported: count.value,
                writable: writableCount
            )
        }

        buffer.didWrite(count.value)
        refilledByteCount += UInt64(count.value)
    }
}
