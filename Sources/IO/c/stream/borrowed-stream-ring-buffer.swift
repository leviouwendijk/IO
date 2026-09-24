/// Fixed-capacity ring storage borrowed from caller-owned mutable bytes.
///
/// `BorrowedStreamRingBuffer` owns only cursor state. Its byte storage belongs
/// to the caller and is valid only for the scoped borrow that created this
/// value. The type is noncopyable and nonescapable so the ring cannot outlive
/// that storage.
///
/// Construction is intentionally file-scoped. Callers enter through
/// `withBorrowedStreamRingBuffer`, which forms the unsafe raw view only for the
/// duration of the closure.
package struct BorrowedStreamRingBuffer: ~Copyable, ~Escapable {
    private let storage: UnsafeMutableRawBufferPointer
    private var state: StreamRingState

    @_lifetime(borrow storage)
    package init(
        storage: borrowing UnsafeMutableRawBufferPointer
    ) {
        let storageCount =
            storage.count

        precondition(
            storageCount > 0,
            "borrowed ring storage must not be empty"
        )

        self.storage =
            copy storage
        self.state =
            StreamRingState(
                capacity: storageCount
            )
    }

    package var capacity: Int {
        state.capacity
    }

    package var readableCount: Int {
        state.readableCount
    }

    package var writableCount: Int {
        state.writableCount
    }

    package var isEmpty: Bool {
        state.isEmpty
    }

    package var isFull: Bool {
        state.isFull
    }

    package func withReadableRegions<Result>(
        _ body: (
            UnsafeRawBufferPointer,
            UnsafeRawBufferPointer
        ) throws -> Result
    ) rethrows -> Result {
        let ranges =
            state.readableRanges()

        let first =
            UnsafeRawBufferPointer(
                start:
                    storage.baseAddress.map {
                        $0.advanced(
                            by:
                                ranges.first.lowerBound
                        )
                    },
                count:
                    ranges.first.count
            )
        let second =
            UnsafeRawBufferPointer(
                start:
                    storage.baseAddress.map {
                        $0.advanced(
                            by:
                                ranges.second.lowerBound
                        )
                    },
                count:
                    ranges.second.count
            )

        return try body(
            first,
            second
        )
    }

    @_lifetime(self: copy self)
    package mutating func withWritableRegions<Result>(
        _ body: (
            UnsafeMutableRawBufferPointer,
            UnsafeMutableRawBufferPointer
        ) throws -> Result
    ) rethrows -> Result {
        let ranges =
            state.writableRanges()

        let first =
            UnsafeMutableRawBufferPointer(
                start:
                    storage.baseAddress.map {
                        $0.advanced(
                            by:
                                ranges.first.lowerBound
                        )
                    },
                count:
                    ranges.first.count
            )
        let second =
            UnsafeMutableRawBufferPointer(
                start:
                    storage.baseAddress.map {
                        $0.advanced(
                            by:
                                ranges.second.lowerBound
                        )
                    },
                count:
                    ranges.second.count
            )

        return try body(
            first,
            second
        )
    }

    @_lifetime(self: copy self)
    package mutating func didWrite(
        _ count: Int
    ) {
        state.didWrite(
            count
        )
    }

    @_lifetime(self: copy self)
    package mutating func consume(
        _ count: Int
    ) {
        state.consume(
            count
        )
    }

    @_lifetime(self: copy self)
    package mutating func append(
        _ byte: UInt8
    ) -> Bool {
        guard state.writableCount > 0 else {
            return false
        }

        storage[
            state.writeIndex
        ] = byte
        state.didWrite(
            1
        )
        return true
    }

    @_lifetime(self: copy self)
    package mutating func append(
        _ bytes: UnsafeRawBufferPointer
    ) -> Int {
        let accepted =
            min(
                bytes.count,
                state.writableCount
            )

        guard accepted > 0 else {
            return 0
        }

        var copied = 0

        withWritableRegions {
            first,
            second in

            if !first.isEmpty,
               let destination =
                    first.baseAddress,
               let source =
                    bytes.baseAddress
            {
                let count =
                    min(
                        first.count,
                        accepted
                    )

                destination.copyMemory(
                    from: source,
                    byteCount: count
                )
                copied +=
                    count
            }

            if copied < accepted,
               !second.isEmpty,
               let destination =
                    second.baseAddress,
               let source =
                    bytes.baseAddress
            {
                let count =
                    accepted - copied

                destination.copyMemory(
                    from:
                        source.advanced(
                            by: copied
                        ),
                    byteCount: count
                )
                copied +=
                    count
            }
        }

        state.didWrite(
            copied
        )
        return copied
    }
}

/// Runs a borrowed ring over caller-owned dynamic-array storage.
///
/// The raw storage view exists only for this call. Because the ring is
/// `~Escapable`, it can be passed through nested calls inside `body` but cannot
/// be returned from this function or stored beyond the borrow.
package func withBorrowedStreamRingBuffer<Result>(
    storage: inout [UInt8],
    _ body: (
        inout BorrowedStreamRingBuffer
    ) throws -> Result
) rethrows -> Result {
    try storage.withUnsafeMutableBytes {
        rawStorage in

        var ring =
            BorrowedStreamRingBuffer(
                storage: rawStorage
            )

        return try body(
            &ring
        )
    }
}

/// Runs a borrowed ring over caller-supplied mutable raw storage.
///
/// This is the floor-neutral scoped entry point for temporary/stack-like
/// storage. A caller can create the storage with
/// `withUnsafeTemporaryAllocation`, then pass its raw buffer here. The ring is
/// `~Escapable`, so it may be passed through nested calls inside `body` but
/// cannot escape this call.
package func withBorrowedStreamRingBuffer<Result>(
    storage: borrowing UnsafeMutableRawBufferPointer,
    _ body: (
        inout BorrowedStreamRingBuffer
    ) throws -> Result
) rethrows -> Result {
    var ring =
        BorrowedStreamRingBuffer(
            storage: storage
        )

    return try body(
        &ring
    )
}
