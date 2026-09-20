import IO

/// Test-only erased contiguous source preserving the pre-ring production representation.
/// It exists only as an A/B/C/D benchmark reference after production `Source` converges
/// on ring storage.
struct ErasedContiguousSource: ~Copyable {
    private var backend: any SourceBackend & ~Copyable
    private var buffer: StreamBuffer
    private var ended: Bool
    private var refillCallCount: UInt64
    private var refilledByteCount: UInt64

    init<Backend: SourceBackend & ~Copyable>(
        _ backend: consuming Backend,
        bufferCapacity: BufferCapacity
    ) {
        self.backend = consume backend
        self.buffer = StreamBuffer(capacity: bufferCapacity)
        self.ended = false
        self.refillCallCount = 0
        self.refilledByteCount = 0
    }

    var bufferedByteCount: Int { buffer.readableCount }
    var refillCalls: UInt64 { refillCallCount }
    var refilledBytes: UInt64 { refilledByteCount }
    var bufferCompactionStatistics: StreamBufferCompactionStatistics {
        buffer.compactionStatistics
    }

    mutating func consume(_ count: Int) throws {
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

    mutating func requestMore() throws -> SourceAvailability {
        guard !ended else { return .end }

        buffer.compact()
        guard buffer.writableCount > 0 else { return .buffer_full }
        let writableCount = buffer.writableCount

        while true {
            refillCallCount += 1
            let refill = try buffer.withWritableBytes { writable in
                try backend.refill(into: writable)
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

/// Test-only erased contiguous destination preserving the pre-ring production
/// representation for dispatch/storage decomposition.
struct ErasedContiguousDestination: ~Copyable {
    private var backend: any DestinationBackend & ~Copyable
    private var buffer: StreamBuffer
    private var drainCallCount: UInt64
    private var drainedByteCount: UInt64
    private var directDrainCallCount: UInt64

    init<Backend: DestinationBackend & ~Copyable>(
        _ backend: consuming Backend,
        bufferCapacity: BufferCapacity
    ) {
        self.backend = consume backend
        self.buffer = StreamBuffer(capacity: bufferCapacity)
        self.drainCallCount = 0
        self.drainedByteCount = 0
        self.directDrainCallCount = 0
    }

    var bufferedByteCount: Int { buffer.readableCount }
    var drainCalls: UInt64 { drainCallCount }
    var drainedBytes: UInt64 { drainedByteCount }
    var directDrainCount: UInt64 { directDrainCallCount }
    var bufferCompactionStatistics: StreamBufferCompactionStatistics {
        buffer.compactionStatistics
    }

    mutating func write(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationWrite {
        guard !bytes.isEmpty else { return .complete }

        var accepted = 0
        while accepted < bytes.count {
            let remaining = UnsafeRawBufferPointer(
                start: bytes.baseAddress.map { $0.advanced(by: accepted) },
                count: bytes.count - accepted
            )

            if buffer.isEmpty && remaining.count > buffer.capacity {
                switch try drainDirect(remaining) {
                case .bytes(let count):
                    accepted += count.value
                    continue
                case .unavailable:
                    return try unavailableWrite(after: accepted)
                }
            }

            if buffer.writableCount == 0 {
                switch try drainBufferedOnce() {
                case .bytes:
                    break
                case .unavailable:
                    return try unavailableWrite(after: accepted)
                }
            }

            let appended = buffer.append(remaining)
            precondition(appended > 0)
            accepted += appended
        }

        return .complete
    }

    mutating func flush() throws -> DestinationFlush {
        while !buffer.isEmpty {
            switch try drainBufferedOnce() {
            case .bytes:
                continue
            case .unavailable:
                return .unavailable
            }
        }
        return try backend.flush()
    }

    private mutating func drainBufferedOnce() throws -> DestinationDrain {
        let offeredCount = buffer.readableCount
        drainCallCount += 1
        let result = try buffer.withReadableBytes { readable in
            try backend.drain(readable)
        }

        switch result {
        case .bytes(let count):
            try check(count, offeredCount: offeredCount)
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
        let result = try backend.drain(bytes)

        switch result {
        case .bytes(let count):
            try check(count, offeredCount: bytes.count)
            drainedByteCount += UInt64(count.value)
            return result
        case .unavailable:
            return .unavailable
        }
    }

    private func check(
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
    ) throws -> DestinationWrite {
        guard accepted > 0 else { return .unavailable }
        return .partial(try PositiveByteCount(accepted))
    }
}


/// Test-only generic contiguous source used to isolate backend specialization from
/// storage representation. Semantics mirror the production contiguous `Source` hot path,
/// but the backend remains a concrete generic type instead of an existential.
struct GenericContiguousSource<Backend: SourceBackend & ~Copyable>: ~Copyable {
    private var backend: Backend
    private var buffer: StreamBuffer
    private var ended: Bool
    private var refillCallCount: UInt64
    private var refilledByteCount: UInt64

    init(
        _ backend: consuming Backend,
        bufferCapacity: BufferCapacity
    ) {
        self.backend = consume backend
        self.buffer = StreamBuffer(capacity: bufferCapacity)
        self.ended = false
        self.refillCallCount = 0
        self.refilledByteCount = 0
    }

    var bufferedByteCount: Int {
        borrowing get { buffer.readableCount }
    }

    var refillCalls: UInt64 {
        borrowing get { refillCallCount }
    }

    var refilledBytes: UInt64 {
        borrowing get { refilledByteCount }
    }

    var bufferCompactionStatistics: StreamBufferCompactionStatistics {
        borrowing get { buffer.compactionStatistics }
    }

    mutating func consume(_ count: Int) throws {
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

    mutating func requestMore() throws -> SourceAvailability {
        guard !ended else {
            return .end
        }

        buffer.compact()

        guard buffer.writableCount > 0 else {
            return .buffer_full
        }

        let writableCount = buffer.writableCount

        while true {
            refillCallCount += 1
            let refill = try buffer.withWritableBytes { writable in
                try backend.refill(into: writable)
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

/// Same contiguous storage/cursor mechanics as `GenericContiguousSource`, but calls the
/// vector backend contract with one real writable region and an empty second region.
/// B→C therefore measures call shape while keeping storage identical.
struct GenericContiguousVectorSource<Backend: SourceBackend & ~Copyable>: ~Copyable {
    private var backend: Backend
    private var buffer: StreamBuffer
    private var ended: Bool
    private var refillCallCount: UInt64
    private var refilledByteCount: UInt64

    init(
        _ backend: consuming Backend,
        bufferCapacity: BufferCapacity
    ) {
        self.backend = consume backend
        self.buffer = StreamBuffer(capacity: bufferCapacity)
        self.ended = false
        self.refillCallCount = 0
        self.refilledByteCount = 0
    }

    var bufferedByteCount: Int {
        borrowing get { buffer.readableCount }
    }

    var refillCalls: UInt64 {
        borrowing get { refillCallCount }
    }

    var refilledBytes: UInt64 {
        borrowing get { refilledByteCount }
    }

    var bufferCompactionStatistics: StreamBufferCompactionStatistics {
        borrowing get { buffer.compactionStatistics }
    }

    mutating func consume(_ count: Int) throws {
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

    mutating func requestMore() throws -> SourceAvailability {
        guard !ended else {
            return .end
        }

        buffer.compact()

        guard buffer.writableCount > 0 else {
            return .buffer_full
        }

        let writableCount = buffer.writableCount
        let empty = UnsafeMutableRawBufferPointer(start: nil, count: 0)

        while true {
            refillCallCount += 1
            let refill = try buffer.withWritableBytes { writable in
                try backend.refill(
                    first: writable,
                    second: empty
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

/// Test-only generic contiguous destination mirroring production Destination buffering
/// while retaining a concrete scalar backend.
struct GenericContiguousDestination<Backend: DestinationBackend & ~Copyable>: ~Copyable {
    private var backend: Backend
    private var buffer: StreamBuffer
    private var drainCallCount: UInt64
    private var drainedByteCount: UInt64
    private var flushCallCount: UInt64
    private var directDrainCallCount: UInt64

    init(
        _ backend: consuming Backend,
        bufferCapacity: BufferCapacity
    ) {
        self.backend = consume backend
        self.buffer = StreamBuffer(capacity: bufferCapacity)
        self.drainCallCount = 0
        self.drainedByteCount = 0
        self.flushCallCount = 0
        self.directDrainCallCount = 0
    }

    var bufferedByteCount: Int {
        borrowing get { buffer.readableCount }
    }

    var drainCalls: UInt64 {
        borrowing get { drainCallCount }
    }

    var drainedBytes: UInt64 {
        borrowing get { drainedByteCount }
    }

    var bufferCompactionStatistics: StreamBufferCompactionStatistics {
        borrowing get { buffer.compactionStatistics }
    }

    var directDrainCount: UInt64 {
        borrowing get { directDrainCallCount }
    }

    mutating func write(_ bytes: [UInt8]) throws -> DestinationWrite {
        try bytes.withUnsafeBytes { try write($0) }
    }

    mutating func write(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationWrite {
        guard !bytes.isEmpty else {
            return .complete
        }

        var accepted = 0

        while accepted < bytes.count {
            let remaining = slice(bytes, from: accepted)

            if buffer.isEmpty && remaining.count > buffer.capacity {
                switch try drainDirect(remaining) {
                case .bytes(let count):
                    accepted += count.value
                    continue
                case .unavailable:
                    return try unavailableWrite(after: accepted)
                }
            }

            if buffer.writableCount == 0 {
                switch try drainBufferedOnce() {
                case .bytes:
                    break
                case .unavailable:
                    return try unavailableWrite(after: accepted)
                }
            }

            let appended = buffer.append(remaining)
            precondition(appended > 0)
            accepted += appended
        }

        return .complete
    }

    mutating func flush() throws -> DestinationFlush {
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
        let result = try buffer.withReadableBytes { readable in
            try backend.drain(readable)
        }

        switch result {
        case .bytes(let count):
            try checkDrainCount(count, offeredCount: offeredCount)
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
        let result = try backend.drain(bytes)

        switch result {
        case .bytes(let count):
            try checkDrainCount(count, offeredCount: bytes.count)
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

    private func unavailableWrite(after accepted: Int) throws -> DestinationWrite {
        guard accepted > 0 else {
            return .unavailable
        }
        return .partial(try PositiveByteCount(accepted))
    }

    private func slice(
        _ bytes: UnsafeRawBufferPointer,
        from offset: Int
    ) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(
            start: bytes.baseAddress.map { $0.advanced(by: offset) },
            count: bytes.count - offset
        )
    }
}

/// Same contiguous storage as `GenericContiguousDestination`, but one-region vector
/// drains isolate vector call shape from ring storage.
struct GenericContiguousVectorDestination<Backend: DestinationBackend & ~Copyable>: ~Copyable {
    private var backend: Backend
    private var buffer: StreamBuffer
    private var drainCallCount: UInt64
    private var drainedByteCount: UInt64
    private var flushCallCount: UInt64
    private var directDrainCallCount: UInt64

    init(
        _ backend: consuming Backend,
        bufferCapacity: BufferCapacity
    ) {
        self.backend = consume backend
        self.buffer = StreamBuffer(capacity: bufferCapacity)
        self.drainCallCount = 0
        self.drainedByteCount = 0
        self.flushCallCount = 0
        self.directDrainCallCount = 0
    }

    var bufferedByteCount: Int {
        borrowing get { buffer.readableCount }
    }

    var drainCalls: UInt64 {
        borrowing get { drainCallCount }
    }

    var drainedBytes: UInt64 {
        borrowing get { drainedByteCount }
    }

    var bufferCompactionStatistics: StreamBufferCompactionStatistics {
        borrowing get { buffer.compactionStatistics }
    }

    var directDrainCount: UInt64 {
        borrowing get { directDrainCallCount }
    }

    mutating func write(_ bytes: [UInt8]) throws -> DestinationWrite {
        try bytes.withUnsafeBytes { try write($0) }
    }

    mutating func write(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationWrite {
        guard !bytes.isEmpty else {
            return .complete
        }

        var accepted = 0

        while accepted < bytes.count {
            let remaining = slice(bytes, from: accepted)

            if buffer.isEmpty && remaining.count > buffer.capacity {
                switch try drainDirect(remaining) {
                case .bytes(let count):
                    accepted += count.value
                    continue
                case .unavailable:
                    return try unavailableWrite(after: accepted)
                }
            }

            if buffer.writableCount == 0 {
                switch try drainBufferedOnce() {
                case .bytes:
                    break
                case .unavailable:
                    return try unavailableWrite(after: accepted)
                }
            }

            let appended = buffer.append(remaining)
            precondition(appended > 0)
            accepted += appended
        }

        return .complete
    }

    mutating func flush() throws -> DestinationFlush {
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
        let empty = UnsafeRawBufferPointer(start: nil, count: 0)
        let result = try buffer.withReadableBytes { readable in
            try backend.drain(
                first: readable,
                second: empty
            )
        }

        switch result {
        case .bytes(let count):
            try checkDrainCount(count, offeredCount: offeredCount)
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
        let empty = UnsafeRawBufferPointer(start: nil, count: 0)
        let result = try backend.drain(
            first: bytes,
            second: empty
        )

        switch result {
        case .bytes(let count):
            try checkDrainCount(count, offeredCount: bytes.count)
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

    private func unavailableWrite(after accepted: Int) throws -> DestinationWrite {
        guard accepted > 0 else {
            return .unavailable
        }
        return .partial(try PositiveByteCount(accepted))
    }

    private func slice(
        _ bytes: UnsafeRawBufferPointer,
        from offset: Int
    ) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(
            start: bytes.baseAddress.map { $0.advanced(by: offset) },
            count: bytes.count - offset
        )
    }
}
