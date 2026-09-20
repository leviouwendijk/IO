import IO

/// Experimental ring-backed counterpart to `Source`.
///
/// This type exists to measure storage representation independently of the production
/// `Source`. It retains unread bytes across refills without compaction and offers the
/// ring's two writable regions to a vector-capable backend in one refill boundary.
package struct RingSource<Backend: SourceBackend & ~Copyable>: ~Copyable {
    private var backend: Backend
    private var buffer: StreamRingBuffer
    private var ended: Bool
    private var refillCallCount: UInt64
    private var refilledByteCount: UInt64
    private var splitRefillCallCount: UInt64

    package init(
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

    package var bufferedByteCount: Int {
        borrowing get { buffer.readableCount }
    }

    package var hasReachedEnd: Bool {
        borrowing get { ended }
    }

    package var isExhausted: Bool {
        borrowing get { ended && buffer.isEmpty }
    }

    package var statistics: SourceStatistics {
        borrowing get {
            .init(
                refillCallCount: refillCallCount,
                refilledByteCount: refilledByteCount
            )
        }
    }

    package var splitRefillCount: UInt64 {
        borrowing get { splitRefillCallCount }
    }

    package borrowing func withReadableRegions<Result>(
        _ body: (UnsafeRawBufferPointer, UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try buffer.withReadableRegions(body)
    }

    package mutating func consume(_ count: Int) throws {
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

    package mutating func prepare() throws -> SourceAvailability {
        if !buffer.isEmpty {
            return .bytes
        }
        if ended {
            return .end
        }
        return try requestMore()
    }

    package mutating func requestMore() throws -> SourceAvailability {
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
                return try backend.refill(first: first, second: second)
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
