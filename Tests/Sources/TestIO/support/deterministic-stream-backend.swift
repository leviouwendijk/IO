import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Deterministic byte-progress schedule used to separate buffer mechanics from kernel
/// pacing. Successful calls are bounded independently for refill and drain; optional
/// cadence values inject `.unavailable` before any progress on every Nth boundary call.
struct DeterministicStreamSchedule: Sendable, Equatable {
    let maximumRefillBytes: Int
    let maximumDrainBytes: Int
    let sourceUnavailableEvery: Int?
    let destinationUnavailableEvery: Int?

    init(
        maximumRefillBytes: Int,
        maximumDrainBytes: Int,
        sourceUnavailableEvery: Int? = nil,
        destinationUnavailableEvery: Int? = nil
    ) {
        precondition(maximumRefillBytes > 0)
        precondition(maximumDrainBytes > 0)
        if let sourceUnavailableEvery {
            precondition(sourceUnavailableEvery > 1)
        }
        if let destinationUnavailableEvery {
            precondition(destinationUnavailableEvery > 1)
        }

        self.maximumRefillBytes = maximumRefillBytes
        self.maximumDrainBytes = maximumDrainBytes
        self.sourceUnavailableEvery = sourceUnavailableEvery
        self.destinationUnavailableEvery = destinationUnavailableEvery
    }
}

/// Source fixture that implements both scalar and two-region refill contracts with the
/// same deterministic progress schedule.
struct DeterministicStreamSourceBackend:
    SourceBackend,
    ~Copyable
{
    private var remainingByteCount: Int
    private let schedule: DeterministicStreamSchedule
    private var callCount: UInt64

    init(
        byteCount: Int,
        schedule: DeterministicStreamSchedule
    ) {
        precondition(byteCount >= 0)
        self.remainingByteCount = byteCount
        self.schedule = schedule
        self.callCount = 0
    }

    mutating func refill(
        into bytes: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        guard remainingByteCount > 0 else {
            return .end
        }

        callCount += 1
        if shouldInjectUnavailable(
            callCount: callCount,
            every: schedule.sourceUnavailableEvery
        ) {
            return .unavailable
        }

        let count = min(
            bytes.count,
            min(schedule.maximumRefillBytes, remainingByteCount)
        )
        guard count > 0 else {
            return .unavailable
        }

        fillDeterministicBytes(
            bytes,
            count: count
        )
        remainingByteCount -= count

        let progress = try PositiveByteCount(count)
        return remainingByteCount == 0
            ? .final_bytes(progress)
            : .bytes(progress)
    }

    mutating func refill(
        first: UnsafeMutableRawBufferPointer,
        second: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        guard remainingByteCount > 0 else {
            return .end
        }

        callCount += 1
        if shouldInjectUnavailable(
            callCount: callCount,
            every: schedule.sourceUnavailableEvery
        ) {
            return .unavailable
        }

        let writableCount = first.count + second.count
        let count = min(
            writableCount,
            min(schedule.maximumRefillBytes, remainingByteCount)
        )
        guard count > 0 else {
            return .unavailable
        }

        let firstCount = min(first.count, count)
        fillDeterministicBytes(
            first,
            count: firstCount
        )

        let secondCount = count - firstCount
        if secondCount > 0 {
            fillDeterministicBytes(
                second,
                count: secondCount
            )
        }

        remainingByteCount -= count

        let progress = try PositiveByteCount(count)
        return remainingByteCount == 0
            ? .final_bytes(progress)
            : .bytes(progress)
    }
}

/// Destination fixture that implements scalar and two-region drain contracts with the
/// same deterministic progress schedule. It deliberately does not retain payload bytes:
/// the benchmark measures buffer/cursor/copy mechanics rather than output accumulation.
struct DeterministicStreamDestinationBackend:
    DestinationBackend,
    ~Copyable
{
    private let schedule: DeterministicStreamSchedule
    private var callCount: UInt64

    init(
        schedule: DeterministicStreamSchedule
    ) {
        self.schedule = schedule
        self.callCount = 0
    }

    mutating func drain(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        guard !bytes.isEmpty else {
            return .unavailable
        }

        callCount += 1
        if shouldInjectUnavailable(
            callCount: callCount,
            every: schedule.destinationUnavailableEvery
        ) {
            return .unavailable
        }

        let count = min(
            bytes.count,
            schedule.maximumDrainBytes
        )
        return .bytes(
            try PositiveByteCount(count)
        )
    }

    mutating func drain(
        first: UnsafeRawBufferPointer,
        second: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        let offeredCount = first.count + second.count
        guard offeredCount > 0 else {
            return .unavailable
        }

        callCount += 1
        if shouldInjectUnavailable(
            callCount: callCount,
            every: schedule.destinationUnavailableEvery
        ) {
            return .unavailable
        }

        let count = min(
            offeredCount,
            schedule.maximumDrainBytes
        )
        return .bytes(
            try PositiveByteCount(count)
        )
    }

    mutating func flush() throws -> DestinationFlush {
        .complete
    }

    mutating func inspect() -> DestinationBackendInspection {
        .init()
    }
}

@inline(__always)
private func shouldInjectUnavailable(
    callCount: UInt64,
    every cadence: Int?
) -> Bool {
    guard let cadence else {
        return false
    }
    return callCount.isMultiple(
        of: UInt64(cadence)
    )
}

@inline(__always)
private func fillDeterministicBytes(
    _ bytes: UnsafeMutableRawBufferPointer,
    count: Int
) {
    guard count > 0, let base = bytes.baseAddress else {
        return
    }

    #if canImport(Darwin)
    _ = Darwin.memset(
        base,
        0x5A,
        count
    )
    #elseif canImport(Glibc)
    _ = Glibc.memset(
        base,
        0x5A,
        count
    )
    #endif
}
