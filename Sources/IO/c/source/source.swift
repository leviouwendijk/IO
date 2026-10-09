/// Buffered, runtime-polymorphic producer of bytes.
///
/// `Source` owns its ring-backed staging storage. The byte-flow state machine
/// is shared with `BorrowedSource` through `SourceAlgorithm`, so storage
/// ownership does not change refill, EOF, vector-region, or consume semantics.
public struct Source: ~Copyable {
    private var backend:
        any SourceBackend
            & ~Copyable
    private var buffer:
        StreamRingBuffer
    private var state:
        SourceState

    public init<
        Backend:
            SourceBackend
            & ~Copyable
    >(
        _ backend: consuming Backend,
        bufferCapacity:
            BufferCapacity =
                .default
    ) {
        self.backend =
            consume backend
        self.buffer =
            StreamRingBuffer(
                capacity:
                    bufferCapacity
            )
        self.state =
            SourceState()
    }

    public var bufferedByteCount: Int {
        borrowing get {
            buffer.readableCount
        }
    }

    public var hasReachedEnd: Bool {
        borrowing get {
            state.ended
        }
    }

    public var isExhausted: Bool {
        borrowing get {
            state.ended
                && buffer.isEmpty
        }
    }

    public var statistics:
        SourceStatistics
    {
        borrowing get {
            state.statistics
        }
    }

    /// Diagnostic count of refill calls that exposed two physical writable regions.
    package var splitRefillCount: UInt64 {
        borrowing get {
            state.splitRefillCallCount
        }
    }

    /// Compatibility diagnostic retained for benchmark code. Ring storage never compacts.
    package var bufferCompactionStatistics:
        StreamBufferCompactionStatistics
    {
        borrowing get {
            .init(
                callCount: 0,
                movedByteCount: 0
            )
        }
    }

    /// Borrows the complete logical readable buffer as at most two physical regions.
    ///
    /// `first` precedes `second` logically. Either region may be empty. The spans are
    /// non-escapable: they cannot outlive `body`, and `Result` cannot carry them out.
    public borrowing func withReadableRegions<
        Result
    >(
        _ body: (
            RawSpan,
            RawSpan
        ) throws -> Result
    ) rethrows -> Result {
        try buffer
            .withReadableRegions {
                first,
                second in

                try body(
                    RawSpan(_unsafeBytes: first),
                    RawSpan(_unsafeBytes: second)
                )
            }
    }

    /// Borrows the first contiguous readable region.
    ///
    /// Ring-backed storage can wrap, so this region may contain fewer bytes than
    /// `bufferedByteCount`. Algorithms that need the complete logical buffer in one
    /// operation should use `withReadableRegions(_:)`.
    public borrowing func withBytes<
        Result
    >(
        _ body: (
            RawSpan
        ) throws -> Result
    ) rethrows -> Result {
        try buffer
            .withReadableRegions {
                first,
                _ in

                try body(
                    RawSpan(_unsafeBytes: first)
                )
            }
    }

    /// Pointer form of `withReadableRegions(_:)` for package-internal algorithms and
    /// benchmarks. Pointers are valid only for the duration of `body`.
    package borrowing func withUnsafeReadableRegions<
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

    /// Pointer form of `withBytes(_:)` for package-internal algorithms and benchmarks.
    /// The pointer is valid only for the duration of `body`.
    package borrowing func withUnsafeBytes<
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

    public mutating func consume(
        _ count: Int
    ) throws {
        try SourceAlgorithm.consume(
            count,
            buffer: &buffer
        )
    }

    public mutating func prepare()
        throws -> SourceAvailability
    {
        try SourceAlgorithm.prepare(
            backend: &backend,
            buffer: &buffer,
            state: &state
        )
    }

    /// Drives `prepare()` through an explicit IO runtime when the backend reports
    /// temporary unavailability.
    ///
    /// The byte-flow state machine remains synchronous. Suspension occurs only after
    /// `.unavailable`, and only when the erased backend exposes a readiness descriptor.
    public mutating func prepare(
        io: IO,
        deadline: IODeadline? = nil
    ) async throws -> SourceAvailability {
        while true {
            let availability =
                try prepare()

            guard availability
                    == .unavailable
            else {
                return availability
            }

            guard let descriptor =
                backend.readinessDescriptor
            else {
                return .unavailable
            }

            try await io.wait(
                descriptor:
                    descriptor,
                for:
                    .readable,
                deadline:
                    deadline
            )
        }
    }

    /// Appends backend progress behind any unread suffix without relocating it.
    public mutating func requestMore()
        throws -> SourceAvailability
    {
        try SourceAlgorithm.requestMore(
            backend: &backend,
            buffer: &buffer,
            state: &state
        )
    }

    /// Drives `requestMore()` through an explicit IO runtime after endpoint
    /// backpressure while preserving the synchronous buffer-full semantics.
    public mutating func requestMore(
        io: IO,
        deadline: IODeadline? = nil
    ) async throws -> SourceAvailability {
        while true {
            let availability =
                try requestMore()

            guard availability
                    == .unavailable
            else {
                return availability
            }

            guard let descriptor =
                backend.readinessDescriptor
            else {
                return .unavailable
            }

            try await io.wait(
                descriptor:
                    descriptor,
                for:
                    .readable,
                deadline:
                    deadline
            )
        }
    }

    /// Copies at most one prepared logical buffer into caller-owned storage.
    public mutating func read(
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
