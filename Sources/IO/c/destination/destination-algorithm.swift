package struct DestinationState: Sendable {
    package var drainCallCount: UInt64
    package var drainedByteCount: UInt64
    package var flushCallCount: UInt64
    package var splitDrainCallCount: UInt64
    package var directDrainCallCount: UInt64
    package let directBypassPolicy: DestinationDirectBypassPolicy

    /// Backend failure deferred because a multi-byte write had already accepted a
    /// prefix; thrown by the next write or flush.
    package var pendingError: (any Error)?

    package init(
        directBypassPolicy: DestinationDirectBypassPolicy
    ) {
        self.drainCallCount = 0
        self.drainedByteCount = 0
        self.flushCallCount = 0
        self.splitDrainCallCount = 0
        self.directDrainCallCount = 0
        self.directBypassPolicy =
            directBypassPolicy
        self.pendingError = nil
    }

    /// Throws, and clears, a failure deferred by an earlier partial write.
    package mutating func throwPendingError() throws {
        guard let error = pendingError else {
            return
        }

        pendingError = nil
        throw error
    }

    package var statistics: DestinationStatistics {
        .init(
            drainCallCount: drainCallCount,
            drainedByteCount: drainedByteCount,
            flushCallCount: flushCallCount
        )
    }
}

/// Shared Destination state machine independent of staging-storage ownership.
///
/// `Destination` supplies owned ring storage. `BorrowedDestination` supplies a
/// lifetime-bound borrowed ring. Backend dispatch and all byte-flow semantics
/// remain identical.
package enum DestinationAlgorithm {
    package static func write<
        Buffer:
            DestinationRingStorage
            & ~Copyable
            & ~Escapable
    >(
        _ byte: UInt8,
        backend:
            inout any DestinationBackend
                & ~Copyable,
        buffer: inout Buffer,
        state: inout DestinationState
    ) throws -> DestinationWrite {
        try state.throwPendingError()

        if buffer.writableCount == 0 {
            switch try drainBufferedOnce(
                backend: &backend,
                buffer: &buffer,
                state: &state
            ) {
            case .bytes:
                break
            case .unavailable:
                return .unavailable
            }
        }

        let appended =
            buffer.append(
                byte
            )
        precondition(
            appended
        )
        return .complete
    }

    package static func write<
        Buffer:
            DestinationRingStorage
            & ~Copyable
            & ~Escapable
    >(
        _ bytes: UnsafeRawBufferPointer,
        backend:
            inout any DestinationBackend
                & ~Copyable,
        buffer: inout Buffer,
        state: inout DestinationState
    ) throws -> DestinationWrite {
        try state.throwPendingError()

        guard !bytes.isEmpty else {
            return .complete
        }

        var accepted = 0

        while accepted < bytes.count {
            let remaining =
                slice(
                    bytes,
                    from: accepted
                )

            if buffer.isEmpty
                && state.directBypassPolicy
                    .shouldBypass(
                        byteCount:
                            remaining.count,
                        bufferCapacity:
                            buffer.capacity
                    )
            {
                let direct: DestinationDrain

                do {
                    direct = try drainDirect(
                        remaining,
                        backend: &backend,
                        state: &state
                    )
                } catch {
                    return try failedWrite(
                        error,
                        after: accepted,
                        state: &state
                    )
                }

                switch direct {
                case .bytes(let count):
                    accepted +=
                        count.value
                    continue
                case .unavailable:
                    return unavailableWrite(
                        after: accepted
                    )
                }
            }

            if buffer.writableCount == 0 {
                let buffered: DestinationDrain

                do {
                    buffered = try drainBufferedOnce(
                        backend: &backend,
                        buffer: &buffer,
                        state: &state
                    )
                } catch {
                    return try failedWrite(
                        error,
                        after: accepted,
                        state: &state
                    )
                }

                switch buffered {
                case .bytes:
                    break
                case .unavailable:
                    return unavailableWrite(
                        after: accepted
                    )
                }
            }

            let appended =
                buffer.append(
                    remaining
                )
            precondition(
                appended > 0
            )
            accepted +=
                appended
        }

        return .complete
    }

    package static func flush<
        Buffer:
            DestinationRingStorage
            & ~Copyable
            & ~Escapable
    >(
        backend:
            inout any DestinationBackend
                & ~Copyable,
        buffer: inout Buffer,
        state: inout DestinationState
    ) throws -> DestinationFlush {
        try state.throwPendingError()

        while !buffer.isEmpty {
            switch try drainBufferedOnce(
                backend: &backend,
                buffer: &buffer,
                state: &state
            ) {
            case .bytes:
                continue
            case .unavailable:
                return .unavailable
            }
        }

        state.flushCallCount += 1
        return try backend.flush()
    }

    private static func drainBufferedOnce<
        Buffer:
            DestinationRingStorage
            & ~Copyable
            & ~Escapable
    >(
        backend:
            inout any DestinationBackend
                & ~Copyable,
        buffer: inout Buffer,
        state: inout DestinationState
    ) throws -> DestinationDrain {
        let offeredCount =
            buffer.readableCount
        precondition(
            offeredCount > 0
        )

        state.drainCallCount += 1

        let result =
            try buffer.withReadableRegions {
                first,
                second in

                if !first.isEmpty
                    && !second.isEmpty
                {
                    state.splitDrainCallCount +=
                        1
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
                offeredCount:
                    offeredCount
            )
            buffer.consume(
                count.value
            )
            state.drainedByteCount +=
                UInt64(
                    count.value
                )
            return result

        case .unavailable:
            return .unavailable
        }
    }

    private static func drainDirect(
        _ bytes: UnsafeRawBufferPointer,
        backend:
            inout any DestinationBackend
                & ~Copyable,
        state: inout DestinationState
    ) throws -> DestinationDrain {
        state.drainCallCount += 1
        state.directDrainCallCount += 1

        let empty =
            UnsafeRawBufferPointer(
                start: nil,
                count: 0
            )
        let result =
            try backend.drain(
                first: bytes,
                second: empty
            )

        switch result {
        case .bytes(let count):
            try checkDrainCount(
                count,
                offeredCount:
                    bytes.count
            )
            state.drainedByteCount +=
                UInt64(
                    count.value
                )
            return result

        case .unavailable:
            return .unavailable
        }
    }

    private static func checkDrainCount(
        _ count: PositiveByteCount,
        offeredCount: Int
    ) throws {
        guard count.value
                <= offeredCount
        else {
            throw StreamContractError
                .destination_reported_too_many_bytes(
                    reported:
                        count.value,
                    offered:
                        offeredCount
                )
        }
    }

    /// A backend failure with nothing accepted is thrown as-is. With a prefix already
    /// accepted, the prefix is reported and the failure deferred to the next call.
    private static func failedWrite(
        _ error: any Error,
        after accepted: Int,
        state: inout DestinationState
    ) throws -> DestinationWrite {
        guard accepted > 0 else {
            throw error
        }

        state.pendingError = error
        return .partial(
            .knownPositive(
                accepted
            )
        )
    }

    private static func unavailableWrite(
        after accepted: Int
    ) -> DestinationWrite {
        guard accepted > 0 else {
            return .unavailable
        }

        return .partial(
            .knownPositive(
                accepted
            )
        )
    }

    private static func slice(
        _ bytes: UnsafeRawBufferPointer,
        from offset: Int
    ) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(
            start:
                bytes.baseAddress.map {
                    $0.advanced(
                        by: offset
                    )
                },
            count:
                bytes.count - offset
        )
    }
}
