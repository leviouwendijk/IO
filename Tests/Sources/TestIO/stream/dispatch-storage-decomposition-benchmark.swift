import Dispatch
import Foundation
import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif


extension TestIO {
    static func testDispatchStorageDecompositionRepresentations() throws {
        let capacity = try BufferCapacity(8 * 1024)
        let profile = DispatchStorageProfile(
            name: "verification",
            chunkSize: 1024,
            consumeSize: 768,
            producerBurst: 4,
            receiverBurst: 4
        )
        let schedule = DeterministicStreamSchedule(
            maximumRefillBytes: 1024,
            maximumDrainBytes: 768,
            sourceUnavailableEvery: 7,
            destinationUnavailableEvery: 5
        )
        let logicalBytes = 256 * 1024

        let a = try timeDispatchComposedA(
            logicalBytes: logicalBytes,
            capacity: capacity,
            profile: profile,
            schedule: schedule
        )
        let b = try timeDispatchComposedB(
            logicalBytes: logicalBytes,
            capacity: capacity,
            profile: profile,
            schedule: schedule
        )
        let c = try timeDispatchComposedC(
            logicalBytes: logicalBytes,
            capacity: capacity,
            profile: profile,
            schedule: schedule
        )
        _ = try timeDispatchComposedD(
            logicalBytes: logicalBytes,
            capacity: capacity,
            profile: profile,
            schedule: schedule
        )

        try expectEqual(a.compactedBytes, b.compactedBytes, "dispatch A/B contiguous compaction")
        try expectEqual(b.compactedBytes, c.compactedBytes, "dispatch B/C contiguous compaction")
        try expectEqual(a.boundaryCalls, b.boundaryCalls, "dispatch A/B boundary calls")
        try expectEqual(b.boundaryCalls, c.boundaryCalls, "dispatch B/C boundary calls")
        try expectEqual(a.unavailableCount, b.unavailableCount, "dispatch A/B unavailable count")
        try expectEqual(b.unavailableCount, c.unavailableCount, "dispatch B/C unavailable count")
    }
}

extension TestIO {
    static func runDispatchStorageDecompositionBenchmarks(
        heavy: Bool
    ) throws {
        let capacity = try BufferCapacity(64 * 1024)
        let deterministicTarget: UInt64 = heavy ? 90_000_000 : 25_000_000
        let socketTarget: UInt64 = heavy ? 120_000_000 : 35_000_000
        let rounds = heavy ? 5 : 3
        let initialBytes = 8 * 1024 * 1024
        let maximumBytes = 1024 * 1024 * 1024

        let profiles = dispatchStorageProfiles
        let schedules = dispatchStorageSchedules

        print("dispatch/storage decomposition")
        print("  capacity: 64 KiB")
        print("  A = erased contiguous scalar (production Source/Destination shape)")
        print("  B = generic contiguous scalar")
        print("  C = generic contiguous vector (second region always empty)")
        print("  D = generic ring vector")
        print("  A→B = existential/specialization delta")
        print("  B→C = scalar/vector call-shape delta")
        print("  C→D = contiguous/ring storage delta")
        print("  \(rounds) interleaved rounds/variant")
        print("")

        print("SOURCE ONLY · deterministic backend")
        print("")
        for schedule in schedules {
            print("\(schedule.name) · \(schedule.detail)")
            for profile in profiles {
                let logicalBytes = try calibrateDispatchBytes(
                    initialBytes: initialBytes,
                    maximumBytes: maximumBytes,
                    targetNanoseconds: deterministicTarget,
                    quantum: profile.consumeSize
                ) { bytes in
                    try timeDispatchSourceA(
                        logicalBytes: bytes,
                        capacity: capacity,
                        consumeSize: profile.consumeSize,
                        schedule: schedule.backend
                    )
                }

                let samples = try collectDispatchSamples(
                    rounds: rounds,
                    a: { try timeDispatchSourceA(logicalBytes: logicalBytes, capacity: capacity, consumeSize: profile.consumeSize, schedule: schedule.backend) },
                    b: { try timeDispatchSourceB(logicalBytes: logicalBytes, capacity: capacity, consumeSize: profile.consumeSize, schedule: schedule.backend) },
                    c: { try timeDispatchSourceC(logicalBytes: logicalBytes, capacity: capacity, consumeSize: profile.consumeSize, schedule: schedule.backend) },
                    d: { try timeDispatchSourceD(logicalBytes: logicalBytes, capacity: capacity, consumeSize: profile.consumeSize, schedule: schedule.backend) }
                )
                printDispatchRow(
                    label: "\(profile.name) · \(formatDispatchBytes(logicalBytes))",
                    aggregates: samples,
                    diagnostic: "compact A/B/C \(formatDispatchBytes(samples.a.compactedBytes))/\(formatDispatchBytes(samples.b.compactedBytes))/\(formatDispatchBytes(samples.c.compactedBytes)) · D split \(samples.d.splitCount)"
                )
            }
            print("")
        }

        print("DESTINATION ONLY · deterministic backend")
        print("")
        for schedule in schedules {
            print("\(schedule.name) · \(schedule.detail)")
            for profile in profiles {
                let logicalBytes = try calibrateDispatchBytes(
                    initialBytes: initialBytes,
                    maximumBytes: maximumBytes,
                    targetNanoseconds: deterministicTarget,
                    quantum: profile.chunkSize
                ) { bytes in
                    try timeDispatchDestinationA(
                        logicalBytes: bytes,
                        capacity: capacity,
                        profile: profile,
                        schedule: schedule.backend
                    )
                }

                let samples = try collectDispatchSamples(
                    rounds: rounds,
                    a: { try timeDispatchDestinationA(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule.backend) },
                    b: { try timeDispatchDestinationB(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule.backend) },
                    c: { try timeDispatchDestinationC(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule.backend) },
                    d: { try timeDispatchDestinationD(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule.backend) }
                )
                printDispatchRow(
                    label: "\(profile.name) · \(formatDispatchBytes(logicalBytes))",
                    aggregates: samples,
                    diagnostic: "compact A/B/C \(formatDispatchBytes(samples.a.compactedBytes))/\(formatDispatchBytes(samples.b.compactedBytes))/\(formatDispatchBytes(samples.c.compactedBytes)) · D split \(samples.d.splitCount)"
                )
            }
            print("")
        }

        print("COMPOSED · deterministic backend")
        print("")
        for schedule in schedules {
            print("\(schedule.name) · \(schedule.detail)")
            for profile in profiles {
                let logicalBytes = try calibrateDispatchBytes(
                    initialBytes: initialBytes,
                    maximumBytes: maximumBytes,
                    targetNanoseconds: deterministicTarget,
                    quantum: profile.chunkSize
                ) { bytes in
                    try timeDispatchComposedA(
                        logicalBytes: bytes,
                        capacity: capacity,
                        profile: profile,
                        schedule: schedule.backend
                    )
                }

                let samples = try collectDispatchSamples(
                    rounds: rounds,
                    a: { try timeDispatchComposedA(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule.backend) },
                    b: { try timeDispatchComposedB(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule.backend) },
                    c: { try timeDispatchComposedC(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule.backend) },
                    d: { try timeDispatchComposedD(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule.backend) }
                )
                printDispatchRow(
                    label: "\(profile.name) · \(formatDispatchBytes(logicalBytes))",
                    aggregates: samples,
                    diagnostic: "compact A/B/C \(formatDispatchBytes(samples.a.compactedBytes))/\(formatDispatchBytes(samples.b.compactedBytes))/\(formatDispatchBytes(samples.c.compactedBytes)) · D split \(samples.d.splitCount)"
                )
            }
            print("")
        }

        print("COMPOSED · nonblocking socketpair")
        print("")
        for profile in profiles {
            let logicalBytes = try calibrateDispatchBytes(
                initialBytes: initialBytes,
                maximumBytes: maximumBytes,
                targetNanoseconds: socketTarget,
                quantum: profile.chunkSize
            ) { bytes in
                try timeDispatchSocketA(
                    logicalBytes: bytes,
                    capacity: capacity,
                    profile: profile
                )
            }

            let samples = try collectDispatchSamples(
                rounds: rounds,
                a: { try timeDispatchSocketA(logicalBytes: logicalBytes, capacity: capacity, profile: profile) },
                b: { try timeDispatchSocketB(logicalBytes: logicalBytes, capacity: capacity, profile: profile) },
                c: { try timeDispatchSocketC(logicalBytes: logicalBytes, capacity: capacity, profile: profile) },
                d: { try timeDispatchSocketD(logicalBytes: logicalBytes, capacity: capacity, profile: profile) }
            )
            printDispatchRow(
                label: "\(profile.name) · \(formatDispatchBytes(logicalBytes))",
                aggregates: samples,
                diagnostic: "compact A/B/C \(formatDispatchBytes(samples.a.compactedBytes))/\(formatDispatchBytes(samples.b.compactedBytes))/\(formatDispatchBytes(samples.c.compactedBytes)) · D split \(samples.d.splitCount)"
            )
        }

        print("")
        print("interpretation:")
        print("  A→B isolates existential backend erasure versus a concrete generic backend.")
        print("  B→C keeps contiguous StreamBuffer and changes only scalar versus one-region vector calls.")
        print("  C→D keeps generic/vector dispatch and changes contiguous compaction to ring storage.")
        print("  deterministic source/destination-only rows attribute each side before composed effects.")
        print("  socketpair rows retain real kernel pacing; compare them only after the deterministic deltas.")
    }
}

private struct DispatchStorageProfile {
    let name: String
    let chunkSize: Int
    let consumeSize: Int
    let producerBurst: Int
    let receiverBurst: Int
}

private struct DispatchStorageSchedule {
    let name: String
    let detail: String
    let backend: DeterministicStreamSchedule
}

private let dispatchStorageProfiles: [DispatchStorageProfile] = [
    .init(name: "token-ish 256/192 B", chunkSize: 256, consumeSize: 192, producerBurst: 128, receiverBurst: 64),
    .init(name: "stream 4/3 KiB", chunkSize: 4 * 1024, consumeSize: 3 * 1024, producerBurst: 32, receiverBurst: 32),
    .init(name: "body 16/12 KiB", chunkSize: 16 * 1024, consumeSize: 12 * 1024, producerBurst: 16, receiverBurst: 16),
    .init(name: "boundary 64/48 KiB", chunkSize: 64 * 1024, consumeSize: 48 * 1024, producerBurst: 1, receiverBurst: 1),
]

private let dispatchStorageSchedules: [DispatchStorageSchedule] = [
    .init(
        name: "full progress",
        detail: "refill/drain <=64 KiB · no unavailable",
        backend: .init(maximumRefillBytes: 64 * 1024, maximumDrainBytes: 64 * 1024)
    ),
    .init(
        name: "bounded progress",
        detail: "refill <=4 KiB · drain <=3 KiB · no unavailable",
        backend: .init(maximumRefillBytes: 4 * 1024, maximumDrainBytes: 3 * 1024)
    ),
    .init(
        name: "periodic backpressure",
        detail: "refill <=4 KiB / unavailable every 7 · drain <=3 KiB / unavailable every 5",
        backend: .init(
            maximumRefillBytes: 4 * 1024,
            maximumDrainBytes: 3 * 1024,
            sourceUnavailableEvery: 7,
            destinationUnavailableEvery: 5
        )
    ),
]

private struct DispatchStorageSample {
    let nanoseconds: UInt64
    let compactedBytes: UInt64
    let boundaryCalls: UInt64
    let splitCount: UInt64
    let unavailableCount: UInt64
}

private struct DispatchStorageAggregate {
    let minimumNanoseconds: UInt64
    let nanoseconds: UInt64
    let maximumNanoseconds: UInt64
    let compactedBytes: UInt64
    let boundaryCalls: UInt64
    let splitCount: UInt64
    let unavailableCount: UInt64
}

private protocol DispatchSourceDriver: ~Copyable {
    var bufferedByteCount: Int { get }
    var compactedByteCount: UInt64 { get }
    var refillCalls: UInt64 { get }
    var refilledBytes: UInt64 { get }
    var splitRefillCount: UInt64 { get }
    mutating func requestMore() throws -> SourceAvailability
    mutating func consume(_ count: Int) throws
}

private protocol DispatchDestinationDriver: ~Copyable {
    var bufferedByteCount: Int { get }
    var compactedByteCount: UInt64 { get }
    var drainCalls: UInt64 { get }
    var drainedBytes: UInt64 { get }
    var splitDrainCount: UInt64 { get }
    mutating func write(_ bytes: UnsafeRawBufferPointer) throws -> DestinationWrite
    mutating func flush() throws -> DestinationFlush
}

private struct DispatchSourceA: DispatchSourceDriver, ~Copyable {
    private var source: ErasedContiguousSource
    init<Backend: SourceBackend & ~Copyable>(_ backend: consuming Backend, capacity: BufferCapacity) {
        source = ErasedContiguousSource(consume backend, bufferCapacity: capacity)
    }
    var bufferedByteCount: Int { source.bufferedByteCount }
    var compactedByteCount: UInt64 { source.bufferCompactionStatistics.movedByteCount }
    var refillCalls: UInt64 { source.refillCalls }
    var refilledBytes: UInt64 { source.refilledBytes }
    var splitRefillCount: UInt64 { 0 }
    mutating func requestMore() throws -> SourceAvailability { try source.requestMore() }
    mutating func consume(_ count: Int) throws { try source.consume(count) }
}

private struct DispatchSourceB<Backend: SourceBackend & ~Copyable>: DispatchSourceDriver, ~Copyable {
    private var source: GenericContiguousSource<Backend>
    init(_ backend: consuming Backend, capacity: BufferCapacity) {
        source = GenericContiguousSource(consume backend, bufferCapacity: capacity)
    }
    var bufferedByteCount: Int { source.bufferedByteCount }
    var compactedByteCount: UInt64 { source.bufferCompactionStatistics.movedByteCount }
    var refillCalls: UInt64 { source.refillCalls }
    var refilledBytes: UInt64 { source.refilledBytes }
    var splitRefillCount: UInt64 { 0 }
    mutating func requestMore() throws -> SourceAvailability { try source.requestMore() }
    mutating func consume(_ count: Int) throws { try source.consume(count) }
}

private struct DispatchSourceC<Backend: SourceBackend & ~Copyable>: DispatchSourceDriver, ~Copyable {
    private var source: GenericContiguousVectorSource<Backend>
    init(_ backend: consuming Backend, capacity: BufferCapacity) {
        source = GenericContiguousVectorSource(consume backend, bufferCapacity: capacity)
    }
    var bufferedByteCount: Int { source.bufferedByteCount }
    var compactedByteCount: UInt64 { source.bufferCompactionStatistics.movedByteCount }
    var refillCalls: UInt64 { source.refillCalls }
    var refilledBytes: UInt64 { source.refilledBytes }
    var splitRefillCount: UInt64 { 0 }
    mutating func requestMore() throws -> SourceAvailability { try source.requestMore() }
    mutating func consume(_ count: Int) throws { try source.consume(count) }
}

private struct DispatchSourceD<Backend: SourceBackend & ~Copyable>: DispatchSourceDriver, ~Copyable {
    private var source: RingSource<Backend>
    init(_ backend: consuming Backend, capacity: BufferCapacity) {
        source = RingSource(consume backend, bufferCapacity: capacity)
    }
    var bufferedByteCount: Int { source.bufferedByteCount }
    var compactedByteCount: UInt64 { 0 }
    var refillCalls: UInt64 { source.statistics.refillCallCount }
    var refilledBytes: UInt64 { source.statistics.refilledByteCount }
    var splitRefillCount: UInt64 { source.splitRefillCount }
    mutating func requestMore() throws -> SourceAvailability { try source.requestMore() }
    mutating func consume(_ count: Int) throws { try source.consume(count) }
}

private struct DispatchDestinationA: DispatchDestinationDriver, ~Copyable {
    private var destination: ErasedContiguousDestination
    init<Backend: DestinationBackend & ~Copyable>(_ backend: consuming Backend, capacity: BufferCapacity) {
        destination = ErasedContiguousDestination(consume backend, bufferCapacity: capacity)
    }
    var bufferedByteCount: Int { destination.bufferedByteCount }
    var compactedByteCount: UInt64 { destination.bufferCompactionStatistics.movedByteCount }
    var drainCalls: UInt64 { destination.drainCalls }
    var drainedBytes: UInt64 { destination.drainedBytes }
    var splitDrainCount: UInt64 { 0 }
    mutating func write(_ bytes: UnsafeRawBufferPointer) throws -> DestinationWrite { try destination.write(bytes) }
    mutating func flush() throws -> DestinationFlush { try destination.flush() }
}

private struct DispatchDestinationB<Backend: DestinationBackend & ~Copyable>: DispatchDestinationDriver, ~Copyable {
    private var destination: GenericContiguousDestination<Backend>
    init(_ backend: consuming Backend, capacity: BufferCapacity) {
        destination = GenericContiguousDestination(consume backend, bufferCapacity: capacity)
    }
    var bufferedByteCount: Int { destination.bufferedByteCount }
    var compactedByteCount: UInt64 { destination.bufferCompactionStatistics.movedByteCount }
    var drainCalls: UInt64 { destination.drainCalls }
    var drainedBytes: UInt64 { destination.drainedBytes }
    var splitDrainCount: UInt64 { 0 }
    mutating func write(_ bytes: UnsafeRawBufferPointer) throws -> DestinationWrite { try destination.write(bytes) }
    mutating func flush() throws -> DestinationFlush { try destination.flush() }
}

private struct DispatchDestinationC<Backend: DestinationBackend & ~Copyable>: DispatchDestinationDriver, ~Copyable {
    private var destination: GenericContiguousVectorDestination<Backend>
    init(_ backend: consuming Backend, capacity: BufferCapacity) {
        destination = GenericContiguousVectorDestination(consume backend, bufferCapacity: capacity)
    }
    var bufferedByteCount: Int { destination.bufferedByteCount }
    var compactedByteCount: UInt64 { destination.bufferCompactionStatistics.movedByteCount }
    var drainCalls: UInt64 { destination.drainCalls }
    var drainedBytes: UInt64 { destination.drainedBytes }
    var splitDrainCount: UInt64 { 0 }
    mutating func write(_ bytes: UnsafeRawBufferPointer) throws -> DestinationWrite { try destination.write(bytes) }
    mutating func flush() throws -> DestinationFlush { try destination.flush() }
}

private struct DispatchDestinationD<Backend: DestinationBackend & ~Copyable>: DispatchDestinationDriver, ~Copyable {
    private var destination: RingDestination<Backend>
    init(_ backend: consuming Backend, capacity: BufferCapacity) {
        destination = RingDestination(consume backend, bufferCapacity: capacity)
    }
    var bufferedByteCount: Int { destination.bufferedByteCount }
    var compactedByteCount: UInt64 { 0 }
    var drainCalls: UInt64 { destination.statistics.drainCallCount }
    var drainedBytes: UInt64 { destination.statistics.drainedByteCount }
    var splitDrainCount: UInt64 { destination.splitDrainCount }
    mutating func write(_ bytes: UnsafeRawBufferPointer) throws -> DestinationWrite { try destination.write(bytes) }
    mutating func flush() throws -> DestinationFlush { try destination.flush() }
}

private extension TestIO {
    static func timeDispatchSourceA(logicalBytes: Int, capacity: BufferCapacity, consumeSize: Int, schedule: DeterministicStreamSchedule) throws -> DispatchStorageSample {
        try timeDispatchSource(
            source: DispatchSourceA(DeterministicStreamSourceBackend(byteCount: logicalBytes, schedule: schedule), capacity: capacity),
            logicalBytes: logicalBytes,
            consumeSize: consumeSize,
            label: "source A"
        )
    }

    static func timeDispatchSourceB(logicalBytes: Int, capacity: BufferCapacity, consumeSize: Int, schedule: DeterministicStreamSchedule) throws -> DispatchStorageSample {
        try timeDispatchSource(
            source: DispatchSourceB(DeterministicStreamSourceBackend(byteCount: logicalBytes, schedule: schedule), capacity: capacity),
            logicalBytes: logicalBytes,
            consumeSize: consumeSize,
            label: "source B"
        )
    }

    static func timeDispatchSourceC(logicalBytes: Int, capacity: BufferCapacity, consumeSize: Int, schedule: DeterministicStreamSchedule) throws -> DispatchStorageSample {
        try timeDispatchSource(
            source: DispatchSourceC(DeterministicStreamSourceBackend(byteCount: logicalBytes, schedule: schedule), capacity: capacity),
            logicalBytes: logicalBytes,
            consumeSize: consumeSize,
            label: "source C"
        )
    }

    static func timeDispatchSourceD(logicalBytes: Int, capacity: BufferCapacity, consumeSize: Int, schedule: DeterministicStreamSchedule) throws -> DispatchStorageSample {
        try timeDispatchSource(
            source: DispatchSourceD(DeterministicStreamSourceBackend(byteCount: logicalBytes, schedule: schedule), capacity: capacity),
            logicalBytes: logicalBytes,
            consumeSize: consumeSize,
            label: "source D"
        )
    }

    @inline(__always)
    static func timeDispatchSource<Driver: DispatchSourceDriver & ~Copyable>(
        source initialSource: consuming Driver,
        logicalBytes: Int,
        consumeSize: Int,
        label: String
    ) throws -> DispatchStorageSample {
        var source = consume initialSource
        var consumed = 0
        var unavailable: UInt64 = 0
        var stagnant = 0
        let start = DispatchTime.now().uptimeNanoseconds

        while consumed < logicalBytes {
            let before = consumed
            let availability = try source.requestMore()
            if availability == .unavailable {
                unavailable += 1
            }

            if source.bufferedByteCount > 0 {
                let count = min(
                    consumeSize,
                    min(source.bufferedByteCount, logicalBytes - consumed)
                )
                try source.consume(count)
                consumed += count
            }

            if consumed == before {
                stagnant += 1
                if stagnant > 100_000 {
                    throw TestFailure(message: "\(label) stalled")
                }
            } else {
                stagnant = 0
            }
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        try expectEqual(source.refilledBytes, UInt64(logicalBytes), "\(label) refilled bytes")
        return .init(
            nanoseconds: elapsed,
            compactedBytes: source.compactedByteCount,
            boundaryCalls: source.refillCalls,
            splitCount: source.splitRefillCount,
            unavailableCount: unavailable
        )
    }

    static func timeDispatchDestinationA(logicalBytes: Int, capacity: BufferCapacity, profile: DispatchStorageProfile, schedule: DeterministicStreamSchedule) throws -> DispatchStorageSample {
        try timeDispatchDestination(
            destination: DispatchDestinationA(DeterministicStreamDestinationBackend(schedule: schedule), capacity: capacity),
            logicalBytes: logicalBytes,
            profile: profile,
            label: "destination A"
        )
    }

    static func timeDispatchDestinationB(logicalBytes: Int, capacity: BufferCapacity, profile: DispatchStorageProfile, schedule: DeterministicStreamSchedule) throws -> DispatchStorageSample {
        try timeDispatchDestination(
            destination: DispatchDestinationB(DeterministicStreamDestinationBackend(schedule: schedule), capacity: capacity),
            logicalBytes: logicalBytes,
            profile: profile,
            label: "destination B"
        )
    }

    static func timeDispatchDestinationC(logicalBytes: Int, capacity: BufferCapacity, profile: DispatchStorageProfile, schedule: DeterministicStreamSchedule) throws -> DispatchStorageSample {
        try timeDispatchDestination(
            destination: DispatchDestinationC(DeterministicStreamDestinationBackend(schedule: schedule), capacity: capacity),
            logicalBytes: logicalBytes,
            profile: profile,
            label: "destination C"
        )
    }

    static func timeDispatchDestinationD(logicalBytes: Int, capacity: BufferCapacity, profile: DispatchStorageProfile, schedule: DeterministicStreamSchedule) throws -> DispatchStorageSample {
        try timeDispatchDestination(
            destination: DispatchDestinationD(DeterministicStreamDestinationBackend(schedule: schedule), capacity: capacity),
            logicalBytes: logicalBytes,
            profile: profile,
            label: "destination D"
        )
    }

    @inline(__always)
    static func timeDispatchDestination<Driver: DispatchDestinationDriver & ~Copyable>(
        destination initialDestination: consuming Driver,
        logicalBytes: Int,
        profile: DispatchStorageProfile,
        label: String
    ) throws -> DispatchStorageSample {
        var destination = consume initialDestination
        let chunk = Array(repeating: UInt8(0x5A), count: profile.chunkSize)
        var accepted = 0
        var unavailable: UInt64 = 0
        var stagnant = 0
        let start = DispatchTime.now().uptimeNanoseconds

        while accepted < logicalBytes || destination.bufferedByteCount > 0 {
            let beforeAccepted = accepted
            let beforeBuffered = destination.bufferedByteCount

            for _ in 0..<profile.producerBurst where accepted < logicalBytes {
                let requestCount = min(profile.chunkSize, logicalBytes - accepted)
                let result = try chunk.withUnsafeBytes { raw -> DestinationWrite in
                    try destination.write(
                        UnsafeRawBufferPointer(start: raw.baseAddress, count: requestCount)
                    )
                }
                switch result {
                case .complete:
                    accepted += requestCount
                case .partial(let count):
                    accepted += count.value
                    unavailable += 1
                case .unavailable:
                    unavailable += 1
                }
                if result == .unavailable {
                    break
                }
            }

            if destination.bufferedByteCount > 0 {
                if try destination.flush() == .unavailable {
                    unavailable += 1
                }
            }

            if accepted == beforeAccepted && destination.bufferedByteCount == beforeBuffered {
                stagnant += 1
                if stagnant > 100_000 {
                    throw TestFailure(message: "\(label) stalled")
                }
            } else {
                stagnant = 0
            }
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        try expectEqual(destination.drainedBytes, UInt64(logicalBytes), "\(label) drained bytes")
        return .init(
            nanoseconds: elapsed,
            compactedBytes: destination.compactedByteCount,
            boundaryCalls: destination.drainCalls,
            splitCount: destination.splitDrainCount,
            unavailableCount: unavailable
        )
    }

    static func timeDispatchComposedA(logicalBytes: Int, capacity: BufferCapacity, profile: DispatchStorageProfile, schedule: DeterministicStreamSchedule) throws -> DispatchStorageSample {
        try timeDispatchComposed(
            source: DispatchSourceA(DeterministicStreamSourceBackend(byteCount: logicalBytes, schedule: schedule), capacity: capacity),
            destination: DispatchDestinationA(DeterministicStreamDestinationBackend(schedule: schedule), capacity: capacity),
            logicalBytes: logicalBytes,
            profile: profile,
            label: "composed A"
        )
    }

    static func timeDispatchComposedB(logicalBytes: Int, capacity: BufferCapacity, profile: DispatchStorageProfile, schedule: DeterministicStreamSchedule) throws -> DispatchStorageSample {
        try timeDispatchComposed(
            source: DispatchSourceB(DeterministicStreamSourceBackend(byteCount: logicalBytes, schedule: schedule), capacity: capacity),
            destination: DispatchDestinationB(DeterministicStreamDestinationBackend(schedule: schedule), capacity: capacity),
            logicalBytes: logicalBytes,
            profile: profile,
            label: "composed B"
        )
    }

    static func timeDispatchComposedC(logicalBytes: Int, capacity: BufferCapacity, profile: DispatchStorageProfile, schedule: DeterministicStreamSchedule) throws -> DispatchStorageSample {
        try timeDispatchComposed(
            source: DispatchSourceC(DeterministicStreamSourceBackend(byteCount: logicalBytes, schedule: schedule), capacity: capacity),
            destination: DispatchDestinationC(DeterministicStreamDestinationBackend(schedule: schedule), capacity: capacity),
            logicalBytes: logicalBytes,
            profile: profile,
            label: "composed C"
        )
    }

    static func timeDispatchComposedD(logicalBytes: Int, capacity: BufferCapacity, profile: DispatchStorageProfile, schedule: DeterministicStreamSchedule) throws -> DispatchStorageSample {
        try timeDispatchComposed(
            source: DispatchSourceD(DeterministicStreamSourceBackend(byteCount: logicalBytes, schedule: schedule), capacity: capacity),
            destination: DispatchDestinationD(DeterministicStreamDestinationBackend(schedule: schedule), capacity: capacity),
            logicalBytes: logicalBytes,
            profile: profile,
            label: "composed D"
        )
    }

    @inline(__always)
    static func timeDispatchComposed<SourceDriver: DispatchSourceDriver & ~Copyable, DestinationDriver: DispatchDestinationDriver & ~Copyable>(
        source initialSource: consuming SourceDriver,
        destination initialDestination: consuming DestinationDriver,
        logicalBytes: Int,
        profile: DispatchStorageProfile,
        label: String
    ) throws -> DispatchStorageSample {
        var source = consume initialSource
        var destination = consume initialDestination
        let chunk = Array(repeating: UInt8(0x5A), count: profile.chunkSize)

        var accepted = 0
        var consumed = 0
        var unavailable: UInt64 = 0
        var stagnant = 0
        let start = DispatchTime.now().uptimeNanoseconds

        while accepted < logicalBytes || consumed < logicalBytes || destination.bufferedByteCount > 0 {
            let beforeAccepted = accepted
            let beforeConsumed = consumed
            let beforeBuffered = destination.bufferedByteCount

            for _ in 0..<profile.producerBurst where accepted < logicalBytes {
                let requestCount = min(profile.chunkSize, logicalBytes - accepted)
                let result = try chunk.withUnsafeBytes { raw -> DestinationWrite in
                    try destination.write(
                        UnsafeRawBufferPointer(start: raw.baseAddress, count: requestCount)
                    )
                }
                switch result {
                case .complete:
                    accepted += requestCount
                case .partial(let count):
                    accepted += count.value
                    unavailable += 1
                case .unavailable:
                    unavailable += 1
                }
                if result == .unavailable {
                    break
                }
            }

            if destination.bufferedByteCount > 0 {
                if try destination.flush() == .unavailable {
                    unavailable += 1
                }
            }

            for _ in 0..<profile.receiverBurst where consumed < logicalBytes {
                let availability = try source.requestMore()
                if availability == .unavailable {
                    unavailable += 1
                }
                if source.bufferedByteCount > 0 {
                    let count = min(
                        profile.consumeSize,
                        min(source.bufferedByteCount, logicalBytes - consumed)
                    )
                    try source.consume(count)
                    consumed += count
                }
                if availability == .unavailable && source.bufferedByteCount == 0 {
                    break
                }
            }

            if accepted == beforeAccepted && consumed == beforeConsumed && destination.bufferedByteCount == beforeBuffered {
                stagnant += 1
                if stagnant > 100_000 {
                    throw TestFailure(message: "\(label) stalled")
                }
            } else {
                stagnant = 0
            }
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        try expectEqual(source.refilledBytes, UInt64(logicalBytes), "\(label) refilled bytes")
        try expectEqual(destination.drainedBytes, UInt64(logicalBytes), "\(label) drained bytes")
        return .init(
            nanoseconds: elapsed,
            compactedBytes: source.compactedByteCount + destination.compactedByteCount,
            boundaryCalls: source.refillCalls + destination.drainCalls,
            splitCount: source.splitRefillCount + destination.splitDrainCount,
            unavailableCount: unavailable
        )
    }
}

private extension TestIO {
    static func timeDispatchSocketA(logicalBytes: Int, capacity: BufferCapacity, profile: DispatchStorageProfile) throws -> DispatchStorageSample {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard makeDispatchSocketPair(&descriptors) == 0 else {
            throw TestFailure(message: "dispatch A socketpair failed")
        }
        let destinationBackend = try NonblockingSocketBackend(descriptor: descriptors[0])
        let sourceBackend = try NonblockingSocketBackend(descriptor: descriptors[1])
        return try timeDispatchComposed(
            source: DispatchSourceA(sourceBackend, capacity: capacity),
            destination: DispatchDestinationA(destinationBackend, capacity: capacity),
            logicalBytes: logicalBytes,
            profile: profile,
            label: "socket A"
        )
    }

    static func timeDispatchSocketB(logicalBytes: Int, capacity: BufferCapacity, profile: DispatchStorageProfile) throws -> DispatchStorageSample {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard makeDispatchSocketPair(&descriptors) == 0 else {
            throw TestFailure(message: "dispatch B socketpair failed")
        }
        let destinationBackend = try NonblockingSocketBackend(descriptor: descriptors[0])
        let sourceBackend = try NonblockingSocketBackend(descriptor: descriptors[1])
        return try timeDispatchComposed(
            source: DispatchSourceB(sourceBackend, capacity: capacity),
            destination: DispatchDestinationB(destinationBackend, capacity: capacity),
            logicalBytes: logicalBytes,
            profile: profile,
            label: "socket B"
        )
    }

    static func timeDispatchSocketC(logicalBytes: Int, capacity: BufferCapacity, profile: DispatchStorageProfile) throws -> DispatchStorageSample {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard makeDispatchSocketPair(&descriptors) == 0 else {
            throw TestFailure(message: "dispatch C socketpair failed")
        }
        let destinationBackend = try NonblockingSocketBackend(descriptor: descriptors[0])
        let sourceBackend = try NonblockingSocketBackend(descriptor: descriptors[1])
        return try timeDispatchComposed(
            source: DispatchSourceC(sourceBackend, capacity: capacity),
            destination: DispatchDestinationC(destinationBackend, capacity: capacity),
            logicalBytes: logicalBytes,
            profile: profile,
            label: "socket C"
        )
    }

    static func timeDispatchSocketD(logicalBytes: Int, capacity: BufferCapacity, profile: DispatchStorageProfile) throws -> DispatchStorageSample {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard makeDispatchSocketPair(&descriptors) == 0 else {
            throw TestFailure(message: "dispatch D socketpair failed")
        }
        let destinationBackend = try NonblockingSocketBackend(descriptor: descriptors[0])
        let sourceBackend = try NonblockingSocketBackend(descriptor: descriptors[1])
        return try timeDispatchComposed(
            source: DispatchSourceD(sourceBackend, capacity: capacity),
            destination: DispatchDestinationD(destinationBackend, capacity: capacity),
            logicalBytes: logicalBytes,
            profile: profile,
            label: "socket D"
        )
    }

    static func makeDispatchSocketPair(
        _ descriptors: inout [Int32]
    ) -> Int32 {
        descriptors.withUnsafeMutableBufferPointer { buffer in
            #if canImport(Darwin)
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
            #elseif canImport(Glibc)
            Glibc.socketpair(
                AF_UNIX,
                Int32(SOCK_STREAM.rawValue),
                0,
                buffer.baseAddress
            )
            #endif
        }
    }
}

private extension TestIO {
    static func collectDispatchSamples(
        rounds: Int,
        a measureA: () throws -> DispatchStorageSample,
        b measureB: () throws -> DispatchStorageSample,
        c measureC: () throws -> DispatchStorageSample,
        d measureD: () throws -> DispatchStorageSample
    ) throws -> (
        a: DispatchStorageAggregate,
        b: DispatchStorageAggregate,
        c: DispatchStorageAggregate,
        d: DispatchStorageAggregate
    ) {
        var aSamples: [DispatchStorageSample] = []
        var bSamples: [DispatchStorageSample] = []
        var cSamples: [DispatchStorageSample] = []
        var dSamples: [DispatchStorageSample] = []

        for round in 0..<rounds {
            if round.isMultiple(of: 2) {
                aSamples.append(try measureA())
                bSamples.append(try measureB())
                cSamples.append(try measureC())
                dSamples.append(try measureD())
            } else {
                dSamples.append(try measureD())
                cSamples.append(try measureC())
                bSamples.append(try measureB())
                aSamples.append(try measureA())
            }
        }

        return (
            aggregateDispatchSamples(aSamples),
            aggregateDispatchSamples(bSamples),
            aggregateDispatchSamples(cSamples),
            aggregateDispatchSamples(dSamples)
        )
    }

    static func aggregateDispatchSamples(
        _ samples: [DispatchStorageSample]
    ) -> DispatchStorageAggregate {
        let timings = samples.map(\.nanoseconds).sorted()
        let median = timings[timings.count / 2]
        let representative = samples.min {
            distanceDispatch($0.nanoseconds, median) < distanceDispatch($1.nanoseconds, median)
        } ?? samples[0]
        return .init(
            minimumNanoseconds: timings.first ?? median,
            nanoseconds: median,
            maximumNanoseconds: timings.last ?? median,
            compactedBytes: representative.compactedBytes,
            boundaryCalls: representative.boundaryCalls,
            splitCount: representative.splitCount,
            unavailableCount: representative.unavailableCount
        )
    }

    static func printDispatchRow(
        label: String,
        aggregates: (a: DispatchStorageAggregate, b: DispatchStorageAggregate, c: DispatchStorageAggregate, d: DispatchStorageAggregate),
        diagnostic: String
    ) {
        print(label)
        print("  A \(formatDispatchTiming(aggregates.a)) · baseline")
        print(
            String(
                format: "  B %@ · B/A %.3fx",
                formatDispatchTiming(aggregates.b),
                Double(aggregates.b.nanoseconds) / Double(aggregates.a.nanoseconds)
            )
        )
        print(
            String(
                format: "  C %@ · C/B %.3fx · C/A %.3fx",
                formatDispatchTiming(aggregates.c),
                Double(aggregates.c.nanoseconds) / Double(aggregates.b.nanoseconds),
                Double(aggregates.c.nanoseconds) / Double(aggregates.a.nanoseconds)
            )
        )
        print(
            String(
                format: "  D %@ · D/C %.3fx · D/A %.3fx",
                formatDispatchTiming(aggregates.d),
                Double(aggregates.d.nanoseconds) / Double(aggregates.c.nanoseconds),
                Double(aggregates.d.nanoseconds) / Double(aggregates.a.nanoseconds)
            )
        )
        print("  \(diagnostic)")
        print(
            "  calls A/B/C/D \(aggregates.a.boundaryCalls)/\(aggregates.b.boundaryCalls)/\(aggregates.c.boundaryCalls)/\(aggregates.d.boundaryCalls)"
                + " · unavailable \(aggregates.a.unavailableCount)/\(aggregates.b.unavailableCount)/\(aggregates.c.unavailableCount)/\(aggregates.d.unavailableCount)"
        )
    }

    static func calibrateDispatchBytes(
        initialBytes: Int,
        maximumBytes: Int,
        targetNanoseconds: UInt64,
        quantum: Int,
        measure: (Int) throws -> DispatchStorageSample
    ) throws -> Int {
        let calibration = try measure(initialBytes)
        guard calibration.nanoseconds > 0 else {
            return initialBytes
        }

        let scale = max(
            1.0,
            Double(targetNanoseconds) / Double(calibration.nanoseconds)
        )
        let requested = min(
            Double(maximumBytes),
            Double(initialBytes) * scale * 1.08
        )
        let raw = max(initialBytes, Int(requested.rounded(.up)))
        let rounded = ((raw + quantum - 1) / quantum) * quantum
        return min(maximumBytes, rounded)
    }

    static func distanceDispatch(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }

    static func formatDispatchTiming(_ aggregate: DispatchStorageAggregate) -> String {
        "\(formatDispatchMilliseconds(aggregate.nanoseconds))"
            + " [\(formatDispatchMilliseconds(aggregate.minimumNanoseconds))"
            + "…\(formatDispatchMilliseconds(aggregate.maximumNanoseconds))]"
    }

    static func formatDispatchMilliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f ms", Double(nanoseconds) / 1_000_000.0)
    }

    static func formatDispatchBytes(_ bytes: Int) -> String {
        formatDispatchBytes(UInt64(bytes))
    }

    static func formatDispatchBytes(_ bytes: UInt64) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.2f MiB", Double(bytes) / Double(1024 * 1024))
        }
        if bytes >= 1024 {
            return String(format: "%.2f KiB", Double(bytes) / 1024.0)
        }
        return "\(bytes) B"
    }
}
