/// Buffered Destination whose staging bytes are borrowed from caller-owned storage.
///
/// The backend remains uniquely owned by this value, while ring storage is
/// lifetime-bound to the caller. The type cannot escape that storage lifetime.
/// All byte-flow behavior is delegated to the same `DestinationAlgorithm` used
/// by the ordinary owned `Destination`.
@_spi(Testing) public struct BorrowedDestination: ~Copyable, ~Escapable {
    private var backend:
        any DestinationBackend
            & ~Copyable
    private var buffer:
        BorrowedStreamRingBuffer
    private var state:
        DestinationState

    @_lifetime(copy buffer)
    fileprivate init<
        Backend:
            DestinationBackend
            & ~Copyable
    >(
        _ backend: consuming Backend,
        buffer:
            consuming BorrowedStreamRingBuffer,
        directBypassPolicy:
            DestinationDirectBypassPolicy =
                .larger_than_buffer
    ) {
        self.backend =
            consume backend
        self.buffer =
            consume buffer
        self.state =
            DestinationState(
                directBypassPolicy:
                    directBypassPolicy
            )
    }

    @_spi(Testing) public var bufferedByteCount: Int {
        borrowing get {
            buffer.readableCount
        }
    }

    @_spi(Testing) public var statistics:
        DestinationStatistics
    {
        borrowing get {
            state.statistics
        }
    }

    @_spi(Testing) public var splitDrainCount: UInt64 {
        borrowing get {
            state.splitDrainCallCount
        }
    }

    @_spi(Testing) public var directDrainCount: UInt64 {
        borrowing get {
            state.directDrainCallCount
        }
    }

    @_spi(Testing) public mutating func inspectBackend()
        -> DestinationBackendInspection
    {
        backend.inspect()
    }

    @_spi(Testing) public mutating func write(
        _ byte: UInt8
    ) throws -> DestinationWrite {
        try DestinationAlgorithm.write(
            byte,
            backend: &backend,
            buffer: &buffer,
            state: &state
        )
    }

    @_spi(Testing) public mutating func write(
        _ bytes: [UInt8]
    ) throws -> DestinationWrite {
        try bytes.withUnsafeBytes {
            try write(
                $0
            )
        }
    }

    @_spi(Testing) public mutating func write(
        _ bytes:
            UnsafeRawBufferPointer
    ) throws -> DestinationWrite {
        try DestinationAlgorithm.write(
            bytes,
            backend: &backend,
            buffer: &buffer,
            state: &state
        )
    }

    @_spi(Testing) public mutating func flush()
        throws -> DestinationFlush
    {
        try DestinationAlgorithm.flush(
            backend: &backend,
            buffer: &buffer,
            state: &state
        )
    }

    @_spi(Testing) public consuming func close() throws {
        guard try flush() == .complete else {
            throw DestinationCloseError.unflushed(
                bufferedByteCount:
                    buffer.readableCount
            )
        }

        try backend.close()
    }
}

/// Runs a borrowed Destination over caller-supplied mutable raw storage.
///
/// This is the baseline explicit-storage entry point and is intended to be
/// used with `withUnsafeTemporaryAllocation` (or another already-scoped
/// mutable buffer). The borrowed ring is created locally and then moved into
/// the destination before the user body runs, so neither the uniquely owned
/// backend nor ring storage is consumed across another borrow closure.
@_spi(Testing) public func withBorrowedDestination<
    Backend:
        DestinationBackend
        & ~Copyable,
    Result
>(
    _ backend: consuming Backend,
    storage:
        borrowing UnsafeMutableRawBufferPointer,
    directBypassPolicy:
        DestinationDirectBypassPolicy =
            .larger_than_buffer,
    _ body: (
        inout BorrowedDestination
    ) throws -> Result
) rethrows -> Result {
    let ring =
        BorrowedStreamRingBuffer(
            storage: storage
        )

    var destination =
        BorrowedDestination(
            consume backend,
            buffer:
                consume ring,
            directBypassPolicy:
                directBypassPolicy
        )

    return try body(
        &destination
    )
}
