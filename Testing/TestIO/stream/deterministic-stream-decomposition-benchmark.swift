import Dispatch
import Foundation
import IO

extension TestIO {
    static func runDeterministicStreamDecompositionBenchmarks(
        heavy: Bool
    ) throws {
        let capacity = try BufferCapacity(64 * 1024)
        let targetNanoseconds: UInt64 = heavy ? 120_000_000 : 40_000_000
        let rounds = heavy ? 5 : 3
        let initialLogicalBytes = 8 * 1024 * 1024
        let maximumLogicalBytes = 1024 * 1024 * 1024

        let profiles: [DeterministicDecompositionProfile] = [
            .init(name: "token-ish 256/192 B", chunkSize: 256, consumeSize: 192, producerBurst: 128, receiverBurst: 64),
            .init(name: "stream 4/3 KiB", chunkSize: 4 * 1024, consumeSize: 3 * 1024, producerBurst: 32, receiverBurst: 32),
            .init(name: "body 16/12 KiB", chunkSize: 16 * 1024, consumeSize: 12 * 1024, producerBurst: 16, receiverBurst: 16),
            .init(name: "boundary 64/48 KiB", chunkSize: 64 * 1024, consumeSize: 48 * 1024, producerBurst: 1, receiverBurst: 1),
        ]

        let schedules: [DeterministicDecompositionSchedule] = [
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

        print("deterministic stream decomposition · no kernel transport")
        print("  source/destination capacity: 64 KiB")
        print("  samples calibrated from cc baseline toward \(heavy ? "120+" : "40+") ms")
        print("  \(rounds) interleaved rounds/variant")
        print("  cc = contiguous source + contiguous destination")
        print("  rc = ring source + contiguous destination")
        print("  cr = contiguous source + ring destination")
        print("  rr = ring source + ring destination")
        print("")

        for schedule in schedules {
            print("\(schedule.name) · \(schedule.detail)")
            print("")

            for profile in profiles {
                let logicalBytes = try calibratedDeterministicBytes(
                    initialBytes: initialLogicalBytes,
                    maximumBytes: maximumLogicalBytes,
                    targetNanoseconds: targetNanoseconds,
                    chunkSize: profile.chunkSize
                ) { logicalBytes in
                    try timeDeterministicCC(
                        logicalBytes: logicalBytes,
                        capacity: capacity,
                        profile: profile,
                        schedule: schedule.backend
                    )
                }

                var ccSamples: [DeterministicDecompositionSample] = []
                var rcSamples: [DeterministicDecompositionSample] = []
                var crSamples: [DeterministicDecompositionSample] = []
                var rrSamples: [DeterministicDecompositionSample] = []

                for round in 0..<rounds {
                    if round.isMultiple(of: 2) {
                        ccSamples.append(try timeDeterministicCC(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule.backend))
                        rcSamples.append(try timeDeterministicRC(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule.backend))
                        crSamples.append(try timeDeterministicCR(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule.backend))
                        rrSamples.append(try timeDeterministicRR(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule.backend))
                    } else {
                        rrSamples.append(try timeDeterministicRR(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule.backend))
                        crSamples.append(try timeDeterministicCR(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule.backend))
                        rcSamples.append(try timeDeterministicRC(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule.backend))
                        ccSamples.append(try timeDeterministicCC(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule.backend))
                    }
                }

                let cc = aggregateDeterministicSamples(ccSamples)
                let rc = aggregateDeterministicSamples(rcSamples)
                let cr = aggregateDeterministicSamples(crSamples)
                let rr = aggregateDeterministicSamples(rrSamples)

                print("\(profile.name) · \(formatDeterministicBytes(logicalBytes)) logical/sample")
                print("  cc \(formatDeterministicTiming(cc)) · baseline")
                print(String(format: "  rc %@ · %.3fx · source-only ring", formatDeterministicTiming(rc), Double(rc.nanoseconds) / Double(cc.nanoseconds)))
                print(String(format: "  cr %@ · %.3fx · destination-only ring", formatDeterministicTiming(cr), Double(cr.nanoseconds) / Double(cc.nanoseconds)))
                print(String(format: "  rr %@ · %.3fx · both ring", formatDeterministicTiming(rr), Double(rr.nanoseconds) / Double(cc.nanoseconds)))
                print("  cc compaction src/dst \(formatDeterministicBytes(Int(cc.sourceCompactedBytes)))/\(formatDeterministicBytes(Int(cc.destinationCompactedBytes)))")
                print("  rc dest-compaction \(formatDeterministicBytes(Int(rc.destinationCompactedBytes))) · split-read \(rc.splitRefills) · refill calls \(rc.refillCalls)")
                print("  cr src-compaction \(formatDeterministicBytes(Int(cr.sourceCompactedBytes))) · split-write \(cr.splitDrains) · drain calls \(cr.drainCalls)")
                print("  rr split read/write \(rr.splitRefills)/\(rr.splitDrains) · source-unavailable \(rr.sourceUnavailableCount) · destination-backpressure \(rr.destinationBackpressureCount)")
                print("")
            }
        }

        print("interpretation:")
        print("  full-progress isolates storage/cursor mechanics when the backend never stalls.")
        print("  bounded-progress adds short refill/drain behavior without scheduling unavailability.")
        print("  periodic-backpressure retains buffered suffixes deterministically, exposing compaction pressure.")
        print("  compare these rows with --ring-socket-decompose-heavy to attribute kernel pacing effects.")
        print("")
    }

    static func testDeterministicStreamDecompositionBackends() throws {
        let capacity = try BufferCapacity(128)
        let profile = DeterministicDecompositionProfile(
            name: "verification",
            chunkSize: 31,
            consumeSize: 23,
            producerBurst: 4,
            receiverBurst: 3
        )
        let schedule = DeterministicStreamSchedule(
            maximumRefillBytes: 37,
            maximumDrainBytes: 29,
            sourceUnavailableEvery: 5,
            destinationUnavailableEvery: 7
        )
        let logicalBytes = 4 * 1024

        let samples = [
            try timeDeterministicCC(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule),
            try timeDeterministicRC(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule),
            try timeDeterministicCR(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule),
            try timeDeterministicRR(logicalBytes: logicalBytes, capacity: capacity, profile: profile, schedule: schedule),
        ]

        let expected = UInt64(logicalBytes)
        for sample in samples {
            try expectEqual(sample.refilledBytes, expected, "deterministic source bytes")
            try expectEqual(sample.drainedBytes, expected, "deterministic destination bytes")
        }
        try expect(samples[3].sourceUnavailableCount > 0, "deterministic ring source should exercise unavailable")
        try expect(samples[3].destinationBackpressureCount > 0, "deterministic ring destination should exercise backpressure")
    }
}

private struct DeterministicDecompositionProfile {
    let name: String
    let chunkSize: Int
    let consumeSize: Int
    let producerBurst: Int
    let receiverBurst: Int
}

private struct DeterministicDecompositionSchedule {
    let name: String
    let detail: String
    let backend: DeterministicStreamSchedule
}

private struct DeterministicDecompositionSample {
    let minimumNanoseconds: UInt64
    let nanoseconds: UInt64
    let maximumNanoseconds: UInt64
    let sourceCompactedBytes: UInt64
    let destinationCompactedBytes: UInt64
    let refillCalls: UInt64
    let drainCalls: UInt64
    let refilledBytes: UInt64
    let drainedBytes: UInt64
    let sourceUnavailableCount: UInt64
    let destinationBackpressureCount: UInt64
    let splitRefills: UInt64
    let splitDrains: UInt64
}

private protocol DeterministicSourceDriver: ~Copyable {
    var bufferedByteCount: Int { get }
    var statistics: SourceStatistics { get }
    var compactedByteCount: UInt64 { get }
    var splitRefillCount: UInt64 { get }

    mutating func requestMore() throws -> SourceAvailability
    mutating func consume(_ count: Int) throws
}

private protocol DeterministicDestinationDriver: ~Copyable {
    var bufferedByteCount: Int { get }
    var statistics: DestinationStatistics { get }
    var compactedByteCount: UInt64 { get }
    var splitDrainCount: UInt64 { get }

    mutating func write(_ bytes: UnsafeRawBufferPointer) throws -> DestinationWrite
    mutating func flush() throws -> DestinationFlush
}

private struct ContiguousDeterministicSource: DeterministicSourceDriver, ~Copyable {
    private var source: Source

    init(byteCount: Int, schedule: DeterministicStreamSchedule, capacity: BufferCapacity) {
        let backend = DeterministicStreamSourceBackend(byteCount: byteCount, schedule: schedule)
        self.source = Source(backend, bufferCapacity: capacity)
    }

    var bufferedByteCount: Int { source.bufferedByteCount }
    var statistics: SourceStatistics { source.statistics }
    var compactedByteCount: UInt64 { source.bufferCompactionStatistics.movedByteCount }
    var splitRefillCount: UInt64 { 0 }

    mutating func requestMore() throws -> SourceAvailability { try source.requestMore() }
    mutating func consume(_ count: Int) throws { try source.consume(count) }
}

private struct RingDeterministicSource: DeterministicSourceDriver, ~Copyable {
    private var source: RingSource<DeterministicStreamSourceBackend>

    init(byteCount: Int, schedule: DeterministicStreamSchedule, capacity: BufferCapacity) {
        let backend = DeterministicStreamSourceBackend(byteCount: byteCount, schedule: schedule)
        self.source = RingSource(backend, bufferCapacity: capacity)
    }

    var bufferedByteCount: Int { source.bufferedByteCount }
    var statistics: SourceStatistics { source.statistics }
    var compactedByteCount: UInt64 { 0 }
    var splitRefillCount: UInt64 { source.splitRefillCount }

    mutating func requestMore() throws -> SourceAvailability { try source.requestMore() }
    mutating func consume(_ count: Int) throws { try source.consume(count) }
}

private struct ContiguousDeterministicDestination: DeterministicDestinationDriver, ~Copyable {
    private var destination: Destination

    init(schedule: DeterministicStreamSchedule, capacity: BufferCapacity) {
        let backend = DeterministicStreamDestinationBackend(schedule: schedule)
        self.destination = Destination(backend, bufferCapacity: capacity)
    }

    var bufferedByteCount: Int { destination.bufferedByteCount }
    var statistics: DestinationStatistics { destination.statistics }
    var compactedByteCount: UInt64 { destination.bufferCompactionStatistics.movedByteCount }
    var splitDrainCount: UInt64 { 0 }

    mutating func write(_ bytes: UnsafeRawBufferPointer) throws -> DestinationWrite { try destination.write(bytes) }
    mutating func flush() throws -> DestinationFlush { try destination.flush() }
}

private struct RingDeterministicDestination: DeterministicDestinationDriver, ~Copyable {
    private var destination: RingDestination<DeterministicStreamDestinationBackend>

    init(schedule: DeterministicStreamSchedule, capacity: BufferCapacity) {
        let backend = DeterministicStreamDestinationBackend(schedule: schedule)
        self.destination = RingDestination(backend, bufferCapacity: capacity)
    }

    var bufferedByteCount: Int { destination.bufferedByteCount }
    var statistics: DestinationStatistics { destination.statistics }
    var compactedByteCount: UInt64 { 0 }
    var splitDrainCount: UInt64 { destination.splitDrainCount }

    mutating func write(_ bytes: UnsafeRawBufferPointer) throws -> DestinationWrite { try destination.write(bytes) }
    mutating func flush() throws -> DestinationFlush { try destination.flush() }
}

private extension TestIO {
    static func timeDeterministicCC(
        logicalBytes: Int,
        capacity: BufferCapacity,
        profile: DeterministicDecompositionProfile,
        schedule: DeterministicStreamSchedule
    ) throws -> DeterministicDecompositionSample {
        try timeDeterministic(
            source: ContiguousDeterministicSource(byteCount: logicalBytes, schedule: schedule, capacity: capacity),
            destination: ContiguousDeterministicDestination(schedule: schedule, capacity: capacity),
            logicalBytes: logicalBytes,
            profile: profile,
            label: "cc"
        )
    }

    static func timeDeterministicRC(
        logicalBytes: Int,
        capacity: BufferCapacity,
        profile: DeterministicDecompositionProfile,
        schedule: DeterministicStreamSchedule
    ) throws -> DeterministicDecompositionSample {
        try timeDeterministic(
            source: RingDeterministicSource(byteCount: logicalBytes, schedule: schedule, capacity: capacity),
            destination: ContiguousDeterministicDestination(schedule: schedule, capacity: capacity),
            logicalBytes: logicalBytes,
            profile: profile,
            label: "rc"
        )
    }

    static func timeDeterministicCR(
        logicalBytes: Int,
        capacity: BufferCapacity,
        profile: DeterministicDecompositionProfile,
        schedule: DeterministicStreamSchedule
    ) throws -> DeterministicDecompositionSample {
        try timeDeterministic(
            source: ContiguousDeterministicSource(byteCount: logicalBytes, schedule: schedule, capacity: capacity),
            destination: RingDeterministicDestination(schedule: schedule, capacity: capacity),
            logicalBytes: logicalBytes,
            profile: profile,
            label: "cr"
        )
    }

    static func timeDeterministicRR(
        logicalBytes: Int,
        capacity: BufferCapacity,
        profile: DeterministicDecompositionProfile,
        schedule: DeterministicStreamSchedule
    ) throws -> DeterministicDecompositionSample {
        try timeDeterministic(
            source: RingDeterministicSource(byteCount: logicalBytes, schedule: schedule, capacity: capacity),
            destination: RingDeterministicDestination(schedule: schedule, capacity: capacity),
            logicalBytes: logicalBytes,
            profile: profile,
            label: "rr"
        )
    }

    @inline(__always)
    static func timeDeterministic<SourceDriver, DestinationDriver>(
        source initialSource: consuming SourceDriver,
        destination initialDestination: consuming DestinationDriver,
        logicalBytes: Int,
        profile: DeterministicDecompositionProfile,
        label: String
    ) throws -> DeterministicDecompositionSample
    where
        SourceDriver: DeterministicSourceDriver & ~Copyable,
        DestinationDriver: DeterministicDestinationDriver & ~Copyable
    {
        var source = consume initialSource
        var destination = consume initialDestination
        let chunk = Array(repeating: UInt8(0x5A), count: profile.chunkSize)

        var accepted = 0
        var consumed = 0
        var sourceUnavailableCount: UInt64 = 0
        var destinationBackpressureCount: UInt64 = 0
        var stagnantIterations = 0

        let start = DispatchTime.now().uptimeNanoseconds

        while consumed < logicalBytes
            || accepted < logicalBytes
            || destination.bufferedByteCount > 0
        {
            let beforeAccepted = accepted
            let beforeConsumed = consumed
            let beforeBuffered = destination.bufferedByteCount

            for _ in 0..<profile.producerBurst where accepted < logicalBytes {
                let requestCount = min(profile.chunkSize, logicalBytes - accepted)
                let result = try chunk.withUnsafeBytes { raw -> DestinationWrite in
                    let offered = UnsafeRawBufferPointer(start: raw.baseAddress, count: requestCount)
                    return try destination.write(offered)
                }

                switch result {
                case .complete:
                    accepted += requestCount
                case .partial(let count):
                    accepted += count.value
                    destinationBackpressureCount += 1
                case .unavailable:
                    destinationBackpressureCount += 1
                }

                if result == .unavailable {
                    break
                }
            }

            if destination.bufferedByteCount > 0 {
                if try destination.flush() == .unavailable {
                    destinationBackpressureCount += 1
                }
            }

            for _ in 0..<profile.receiverBurst where consumed < logicalBytes {
                let availability = try source.requestMore()
                if availability == .unavailable {
                    sourceUnavailableCount += 1
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

            if accepted == beforeAccepted
                && consumed == beforeConsumed
                && destination.bufferedByteCount == beforeBuffered
            {
                stagnantIterations += 1
                if stagnantIterations > 100_000 {
                    throw TestFailure(message: "deterministic \(label) decomposition stalled")
                }
            } else {
                stagnantIterations = 0
            }
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let sourceStats = source.statistics
        let destinationStats = destination.statistics

        try expectEqual(sourceStats.refilledByteCount, UInt64(logicalBytes), "deterministic \(label) refilled bytes")
        try expectEqual(destinationStats.drainedByteCount, UInt64(logicalBytes), "deterministic \(label) drained bytes")

        return .init(
            minimumNanoseconds: elapsed,
            nanoseconds: elapsed,
            maximumNanoseconds: elapsed,
            sourceCompactedBytes: source.compactedByteCount,
            destinationCompactedBytes: destination.compactedByteCount,
            refillCalls: sourceStats.refillCallCount,
            drainCalls: destinationStats.drainCallCount,
            refilledBytes: sourceStats.refilledByteCount,
            drainedBytes: destinationStats.drainedByteCount,
            sourceUnavailableCount: sourceUnavailableCount,
            destinationBackpressureCount: destinationBackpressureCount,
            splitRefills: source.splitRefillCount,
            splitDrains: destination.splitDrainCount
        )
    }
}

private extension TestIO {
    static func calibratedDeterministicBytes(
        initialBytes: Int,
        maximumBytes: Int,
        targetNanoseconds: UInt64,
        chunkSize: Int,
        measure: (Int) throws -> DeterministicDecompositionSample
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
            Double(initialBytes) * scale * 1.10
        )
        let raw = max(
            initialBytes,
            Int(requested.rounded(.up))
        )
        let rounded = ((raw + chunkSize - 1) / chunkSize) * chunkSize
        return min(maximumBytes, rounded)
    }

    static func aggregateDeterministicSamples(
        _ samples: [DeterministicDecompositionSample]
    ) -> DeterministicDecompositionSample {
        let timings = samples.map(\.nanoseconds).sorted()
        let middle = timings[timings.count / 2]
        let representative = samples.min {
            deterministicDistance($0.nanoseconds, middle)
                < deterministicDistance($1.nanoseconds, middle)
        } ?? samples[0]

        return .init(
            minimumNanoseconds: timings.first ?? middle,
            nanoseconds: middle,
            maximumNanoseconds: timings.last ?? middle,
            sourceCompactedBytes: representative.sourceCompactedBytes,
            destinationCompactedBytes: representative.destinationCompactedBytes,
            refillCalls: representative.refillCalls,
            drainCalls: representative.drainCalls,
            refilledBytes: representative.refilledBytes,
            drainedBytes: representative.drainedBytes,
            sourceUnavailableCount: representative.sourceUnavailableCount,
            destinationBackpressureCount: representative.destinationBackpressureCount,
            splitRefills: representative.splitRefills,
            splitDrains: representative.splitDrains
        )
    }

    static func deterministicDistance(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }

    static func formatDeterministicTiming(
        _ sample: DeterministicDecompositionSample
    ) -> String {
        "\(formatDeterministicMilliseconds(sample.nanoseconds))"
            + " [\(formatDeterministicMilliseconds(sample.minimumNanoseconds))"
            + "…\(formatDeterministicMilliseconds(sample.maximumNanoseconds))]"
    }

    static func formatDeterministicMilliseconds(
        _ nanoseconds: UInt64
    ) -> String {
        String(
            format: "%.3f ms",
            Double(nanoseconds) / 1_000_000.0
        )
    }

    static func formatDeterministicBytes(
        _ bytes: Int
    ) -> String {
        let value = Double(bytes)
        if bytes >= 1024 * 1024 {
            return String(
                format: "%.2f MiB",
                value / (1024.0 * 1024.0)
            )
        }
        if bytes >= 1024 {
            return String(
                format: "%.2f KiB",
                value / 1024.0
            )
        }
        return "\(bytes) B"
    }
}
