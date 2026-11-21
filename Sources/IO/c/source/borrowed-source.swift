/// Buffered Source whose staging bytes are borrowed from caller-owned storage.
///
/// The backend remains uniquely owned by this value, while ring storage is
/// lifetime-bound to the caller. The type cannot escape that storage lifetime.
/// All byte-flow behavior is delegated to the same `SourceAlgorithm` used by
/// the ordinary owned `Source`.
@_spi(Testing) public struct BorrowedSource: ~Copyable, ~Escapable {
    private var backend:
        any SourceBackend
            & ~Copyable
    private var buffer:
        BorrowedStreamRingBuffer
    private var state:
        SourceState

    @_lifetime(copy buffer)
    fileprivate init<
        Backend:
            SourceBackend
            & ~Copyable
    >(
        _ backend: consuming Backend,
        buffer:
            consuming BorrowedStreamRingBuffer
    ) {
        self.backend =
            consume backend
        self.buffer =
            consume buffer
        self.state =
            SourceState()
    }

    @_spi(Testing) public var bufferedByteCount: Int {
        borrowing get {
            buffer.readableCount
        }
    }

    @_spi(Testing) public var hasReachedEnd: Bool {
        borrowing get {
            state.ended
        }
    }

    @_spi(Testing) public var isExhausted: Bool {
        borrowing get {
            state.ended
                && buffer.isEmpty
        }
    }

    @_spi(Testing) public var statistics:
        SourceStatistics
    {
        borrowing get {
            state.statistics
        }
    }

    @_spi(Testing) public var splitRefillCount: UInt64 {
        borrowing get {
            state.splitRefillCallCount
        }
    }

    @_spi(Testing) public var bufferCompactionStatistics:
        StreamBufferCompactionStatistics
    {
        borrowing get {
            .init(
                callCount: 0,
                movedByteCount: 0
            )
        }
    }

    @_spi(Testing) public borrowing func withReadableRegions<
        Result
    >(
        _ body: (
            UnsafeRawBufferPointer,
            UnsafeRawBufferPointer
        ) throws -> Result
    ) rethrows -> Result {
        try buffer
            .withReadableRegions(
                body
            )
    }

    @_spi(Testing) public borrowing func withBytes<
        Result
    >(
        _ body: (
            UnsafeRawBufferPointer
        ) throws -> Result
    ) rethrows -> Result {
        try buffer
            .withReadableRegions {
                first,
                _ in

                try body(
                    first
                )
            }
    }

    @_spi(Testing) public mutating func consume(
        _ count: Int
    ) throws {
        try SourceAlgorithm.consume(
            count,
            buffer: &buffer
        )
    }

    @_spi(Testing) public mutating func prepare()
        throws -> SourceAvailability
    {
        try SourceAlgorithm.prepare(
            backend: &backend,
            buffer: &buffer,
            state: &state
        )
    }

    @_spi(Testing) public mutating func requestMore()
        throws -> SourceAvailability
    {
        try SourceAlgorithm.requestMore(
            backend: &backend,
            buffer: &buffer,
            state: &state
        )
    }

    @_spi(Testing) public mutating func read(
        into output:
            UnsafeMutableRawBufferPointer
    ) throws -> SourceRead {
        try SourceAlgorithm.read(
            into: output,
            backend: &backend,
            buffer: &buffer,
            state: &state
        )
    }
}

/// Runs a borrowed Source over caller-supplied mutable raw storage.
///
/// This mirrors `withBorrowedDestination`: the borrowed ring and uniquely-owned
/// backend are formed in one scope, moved into the nonescapable endpoint, and
/// only the completed endpoint is exposed to the user body.
@_spi(Testing) public func withBorrowedSource<
    Backend:
        SourceBackend
        & ~Copyable,
    Result
>(
    _ backend: consuming Backend,
    storage:
        borrowing UnsafeMutableRawBufferPointer,
    _ body: (
        inout BorrowedSource
    ) throws -> Result
) rethrows -> Result {
    let ring =
        BorrowedStreamRingBuffer(
            storage: storage
        )

    var source =
        BorrowedSource(
            consume backend,
            buffer:
                consume ring
        )

    return try body(
        &source
    )
}
