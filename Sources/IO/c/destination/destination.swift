/// Buffered, runtime-polymorphic consumer of bytes.
///
/// `Destination` owns its ring-backed staging storage. The byte-flow state
/// machine is shared with `BorrowedDestination` through `DestinationAlgorithm`,
/// so storage ownership does not change short-write, vector-drain, direct
/// bypass, backpressure, or flush semantics.
public struct Destination: ~Copyable {
    private var backend:
        any DestinationBackend
            & ~Copyable
    private var buffer:
        StreamRingBuffer
    private var state:
        DestinationState

    public init<
        Backend:
            DestinationBackend
            & ~Copyable
    >(
        _ backend: consuming Backend,
        bufferCapacity:
            BufferCapacity = .default
    ) {
        self.backend =
            consume backend
        self.buffer =
            StreamRingBuffer(
                capacity:
                    bufferCapacity
            )
        self.state =
            DestinationState(
                directBypassPolicy:
                    .larger_than_buffer
            )
    }

    package init<
        Backend:
            DestinationBackend
            & ~Copyable
    >(
        _ backend: consuming Backend,
        bufferCapacity:
            BufferCapacity,
        directBypassPolicy:
            DestinationDirectBypassPolicy
    ) {
        self.backend =
            consume backend
        self.buffer =
            StreamRingBuffer(
                capacity:
                    bufferCapacity
            )
        self.state =
            DestinationState(
                directBypassPolicy:
                    directBypassPolicy
            )
    }

    public var bufferedByteCount: Int {
        borrowing get {
            buffer.readableCount
        }
    }

    public var statistics:
        DestinationStatistics
    {
        borrowing get {
            state.statistics
        }
    }

    /// Diagnostic count of drains that exposed two physical readable regions.
    package var splitDrainCount: UInt64 {
        borrowing get {
            state.splitDrainCallCount
        }
    }

    package var directDrainCount: UInt64 {
        borrowing get {
            state.directDrainCallCount
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

    public mutating func inspectBackend()
        -> DestinationBackendInspection
    {
        backend.inspect()
    }

    public mutating func write(
        _ byte: UInt8
    ) throws -> DestinationWrite {
        try DestinationAlgorithm.write(
            byte,
            backend: &backend,
            buffer: &buffer,
            state: &state
        )
    }

    public mutating func write(
        _ bytes: [UInt8]
    ) throws -> DestinationWrite {
        try bytes.withUnsafeBytes {
            try write(
                $0
            )
        }
    }

    /// Drives an owned byte array through synchronous Destination backpressure using
    /// the supplied IO runtime. Raw borrowed pointers deliberately remain synchronous
    /// so their lifetime is never extended across suspension.
    public mutating func write(
        _ bytes: [UInt8],
        io: IO,
        deadline: IODeadline? = nil
    ) async throws -> DestinationWrite {
        guard !bytes.isEmpty else {
            return .complete
        }

        var accepted =
            0

        // Accepted bytes are always reported. Once part of `bytes` has been accepted, a
        // write failure is deferred to the next call (as the synchronous path defers it),
        // and a failed wait (deadline, cancellation) returns the progress; the caller's
        // next call observes the same condition again.
        while accepted
                < bytes.count
        {
            let result: DestinationWrite

            do {
                result =
                    try bytes.withUnsafeBytes {
                        raw in

                        let remaining =
                            UnsafeRawBufferPointer(
                                start:
                                    raw.baseAddress?
                                        .advanced(
                                            by:
                                                accepted
                                        ),
                                count:
                                    raw.count
                                        - accepted
                            )

                        return try write(
                            remaining
                        )
                    }
            } catch {
                guard accepted > 0 else {
                    throw error
                }

                state.pendingError = error

                return .partial(
                    try PositiveByteCount(
                        accepted
                    )
                )
            }

            switch result {
            case .complete:
                return .complete

            case .partial(
                let count
            ):
                accepted +=
                    count.value

            case .unavailable:
                break
            }

            guard accepted
                    < bytes.count
            else {
                return .complete
            }

            // The synchronous write deferred a failure behind the prefix it accepted.
            // Report the progress now; the failure surfaces on the next call.
            if state.pendingError != nil {
                return .partial(
                    try PositiveByteCount(
                        accepted
                    )
                )
            }

            guard let descriptor =
                backend.readinessDescriptor
            else {
                guard accepted > 0 else {
                    return .unavailable
                }

                return .partial(
                    try PositiveByteCount(
                        accepted
                    )
                )
            }

            do {
                try await io.wait(
                    descriptor:
                        descriptor,
                    for:
                        .writable,
                    deadline:
                        deadline
                )
            } catch {
                guard accepted > 0 else {
                    throw error
                }

                return .partial(
                    try PositiveByteCount(
                        accepted
                    )
                )
            }
        }

        return .complete
    }

    public mutating func write(
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

    public mutating func flush()
        throws -> DestinationFlush
    {
        try DestinationAlgorithm.flush(
            backend: &backend,
            buffer: &buffer,
            state: &state
        )
    }

    /// Drives buffered Destination bytes to the backend, suspending only when the
    /// synchronous flush reports endpoint backpressure.
    public mutating func flush(
        io: IO,
        deadline: IODeadline? = nil
    ) async throws -> DestinationFlush {
        while true {
            let result =
                try flush()

            guard result
                    == .unavailable
            else {
                return result
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
                    .writable,
                deadline:
                    deadline
            )
        }
    }
}
