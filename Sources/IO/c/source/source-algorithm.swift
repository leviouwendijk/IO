package struct SourceState: Sendable {
    package var ended: Bool
    package var refillCallCount: UInt64
    package var refilledByteCount: UInt64
    package var splitRefillCallCount: UInt64

    package init() {
        self.ended = false
        self.refillCallCount = 0
        self.refilledByteCount = 0
        self.splitRefillCallCount = 0
    }

    package var statistics: SourceStatistics {
        .init(
            refillCallCount: refillCallCount,
            refilledByteCount: refilledByteCount
        )
    }
}

/// Shared Source state machine independent of staging-storage ownership.
///
/// `Source` supplies owned ring storage. `BorrowedSource` supplies a
/// lifetime-bound borrowed ring. Backend dispatch, EOF handling, refill
/// semantics, contract checking, and read/consume behavior remain identical.
package enum SourceAlgorithm {
    package static func consume<
        Buffer:
            SourceRingStorage
            & ~Copyable
            & ~Escapable
    >(
        _ count: Int,
        buffer: inout Buffer
    ) throws {
        guard count >= 0 else {
            throw StreamContractError
                .negative_consume(
                    count
                )
        }

        guard count <= buffer.readableCount else {
            throw StreamContractError
                .consume_exceeds_available(
                    requested:
                        count,
                    available:
                        buffer.readableCount
                )
        }

        buffer.consume(
            count
        )
    }

    package static func prepare<
        Buffer:
            SourceRingStorage
            & ~Copyable
            & ~Escapable
    >(
        backend:
            inout any SourceBackend
                & ~Copyable,
        buffer: inout Buffer,
        state: inout SourceState
    ) throws -> SourceAvailability {
        if !buffer.isEmpty {
            return .bytes
        }

        if state.ended {
            return .end
        }

        return try requestMore(
            backend: &backend,
            buffer: &buffer,
            state: &state
        )
    }

    /// Appends backend progress behind any unread suffix without relocating it.
    package static func requestMore<
        Buffer:
            SourceRingStorage
            & ~Copyable
            & ~Escapable
    >(
        backend:
            inout any SourceBackend
                & ~Copyable,
        buffer: inout Buffer,
        state: inout SourceState
    ) throws -> SourceAvailability {
        guard !state.ended else {
            return .end
        }

        guard buffer.writableCount > 0 else {
            return .buffer_full
        }

        let writableCount =
            buffer.writableCount

        while true {
            state.refillCallCount +=
                1

            let refill =
                try buffer
                    .withWritableRegions {
                        first,
                        second in

                        if !first.isEmpty
                            && !second.isEmpty
                        {
                            state
                                .splitRefillCallCount +=
                                1
                        }

                        return try backend.refill(
                            first: first,
                            second: second
                        )
                    }

            switch refill {
            case .bytes(let count):
                try apply(
                    count,
                    writableCount:
                        writableCount,
                    buffer: &buffer,
                    state: &state
                )
                return .bytes

            case .final_bytes(let count):
                try apply(
                    count,
                    writableCount:
                        writableCount,
                    buffer: &buffer,
                    state: &state
                )
                state.ended =
                    true
                return .bytes

            case .end:
                state.ended =
                    true
                return .end

            case .unavailable:
                return .unavailable

            case .retry:
                continue
            }
        }
    }

    /// Copies at most one prepared logical buffer into caller-owned storage.
    package static func read<
        Buffer:
            SourceRingStorage
            & ~Copyable
            & ~Escapable
    >(
        into output:
            UnsafeMutableRawBufferPointer,
        backend:
            inout any SourceBackend
                & ~Copyable,
        buffer: inout Buffer,
        state: inout SourceState
    ) throws -> SourceRead {
        guard !output.isEmpty else {
            return .empty
        }

        switch try prepare(
            backend: &backend,
            buffer: &buffer,
            state: &state
        ) {
        case .bytes:
            let count =
                min(
                    output.count,
                    buffer.readableCount
                )
            var copied = 0

            buffer.withReadableRegions {
                first,
                second in

                if copied < count,
                   !first.isEmpty,
                   let destination =
                        output.baseAddress,
                   let source =
                        first.baseAddress
                {
                    let amount =
                        min(
                            first.count,
                            count - copied
                        )
                    destination
                        .copyMemory(
                            from: source,
                            byteCount:
                                amount
                        )
                    copied +=
                        amount
                }

                if copied < count,
                   !second.isEmpty,
                   let destination =
                        output.baseAddress,
                   let source =
                        second.baseAddress
                {
                    let amount =
                        min(
                            second.count,
                            count - copied
                        )
                    destination
                        .advanced(
                            by: copied
                        )
                        .copyMemory(
                            from: source,
                            byteCount:
                                amount
                        )
                    copied +=
                        amount
                }
            }

            buffer.consume(
                copied
            )

            return .bytes(
                .knownPositive(
                    copied
                )
            )

        case .end:
            return .end

        case .unavailable:
            return .unavailable

        case .buffer_full:
            return .buffer_full
        }
    }

    private static func apply<
        Buffer:
            SourceRingStorage
            & ~Copyable
            & ~Escapable
    >(
        _ count: PositiveByteCount,
        writableCount: Int,
        buffer: inout Buffer,
        state: inout SourceState
    ) throws {
        guard count.value
                <= writableCount
        else {
            throw StreamContractError
                .source_reported_too_many_bytes(
                    reported:
                        count.value,
                    writable:
                        writableCount
                )
        }

        buffer.didWrite(
            count.value
        )
        state.refilledByteCount +=
            UInt64(
                count.value
            )
    }
}
