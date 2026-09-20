import Dispatch
import IO
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    static func runRingSocketSweepBenchmarks(
        heavy: Bool
    ) throws {
        let capacity = try BufferCapacity(64 * 1024)
        let rounds = heavy ? 5 : 3
        let baseLogicalBytes = heavy ? 16 * 1024 * 1024 : 4 * 1024 * 1024

        let chunkSizes = [
            64,
            128,
            256,
            512,
            1024,
            2 * 1024,
            4 * 1024,
            8 * 1024,
            16 * 1024,
            32 * 1024,
            64 * 1024,
            128 * 1024,
            256 * 1024,
        ]

        let consumeFractions: [(label: String, numerator: Int, denominator: Int)] = [
            ("25%", 1, 4),
            ("50%", 1, 2),
            ("75%", 3, 4),
            ("100%", 1, 1),
        ]

        print("ring socket crossover sweep · nonblocking socketpair")
        print("  source/destination capacity: 64 KiB")
        print("  chunks: 64 B ... 256 KiB")
        print("  consume fraction applies to min(chunk, 64 KiB)")
        print("  >64 KiB rows are large-write bypass regime, not ordinary buffered traffic")
        print("  \(rounds) interleaved rounds/profile")
        print("")

        for chunkSize in chunkSizes {
            let workingSet = min(chunkSize, capacity.value)
            let logicalBytes = max(
                baseLogicalBytes,
                chunkSize * 256
            )
            let burst = max(
                1,
                min(
                    128,
                    (64 * 1024 + chunkSize - 1) / chunkSize
                )
            )
            let regime = chunkSize <= capacity.value
                ? "buffered"
                : "bypass >64 KiB"

            print(
                "chunk \(formatSweepBytes(chunkSize)) · \(regime) · "
                    + "\(formatSweepBytes(logicalBytes)) logical/sample · burst \(burst)"
            )

            for fraction in consumeFractions {
                let consumeSize = max(
                    1,
                    workingSet * fraction.numerator / fraction.denominator
                )
                let profile = RingSocketSweepProfile(
                    chunkSize: chunkSize,
                    consumeSize: consumeSize,
                    producerBurst: burst,
                    receiverBurst: burst
                )

                var contiguousSamples: [RingSocketSweepSample] = []
                var ringSamples: [RingSocketSweepSample] = []

                for round in 0..<rounds {
                    if round.isMultiple(of: 2) {
                        contiguousSamples.append(
                            try timeContiguousSocketSweep(
                                logicalBytes: logicalBytes,
                                capacity: capacity,
                                profile: profile
                            )
                        )
                        ringSamples.append(
                            try timeRingSocketSweep(
                                logicalBytes: logicalBytes,
                                capacity: capacity,
                                profile: profile
                            )
                        )
                    } else {
                        ringSamples.append(
                            try timeRingSocketSweep(
                                logicalBytes: logicalBytes,
                                capacity: capacity,
                                profile: profile
                            )
                        )
                        contiguousSamples.append(
                            try timeContiguousSocketSweep(
                                logicalBytes: logicalBytes,
                                capacity: capacity,
                                profile: profile
                            )
                        )
                    }
                }

                let contiguous = aggregateSweepSamples(contiguousSamples)
                let ring = aggregateSweepSamples(ringSamples)
                let ratio = Double(ring.nanoseconds) / Double(contiguous.nanoseconds)
                let movedBytes = contiguous.sourceCompactedBytes
                    + contiguous.destinationCompactedBytes
                let movedPerUseful = Double(movedBytes) / Double(logicalBytes)
                let compactionCalls = contiguous.sourceCompactionCalls
                    + contiguous.destinationCompactionCalls

                print(
                    String(
                        format: "  %@ consume %@ · cont %@ · ring %@ · ratio %.3fx",
                        fraction.label,
                        formatSweepBytes(consumeSize),
                        formatSweepMilliseconds(contiguous.nanoseconds),
                        formatSweepMilliseconds(ring.nanoseconds),
                        ratio
                    )
                )
                print(
                    String(
                        format: "      compact %llu calls · %@ moved · %.3fx useful "
                            + "(src %@ / dst %@)",
                        compactionCalls,
                        formatSweepBytes(movedBytes),
                        movedPerUseful,
                        formatSweepBytes(contiguous.sourceCompactedBytes),
                        formatSweepBytes(contiguous.destinationCompactedBytes)
                    )
                )
                print(
                    "      refill c/r \(contiguous.refillCalls)/\(ring.refillCalls)"
                        + " · drain c/r \(contiguous.drainCalls)/\(ring.drainCalls)"
                        + " · source-unavail c/r \(contiguous.sourceUnavailableCount)/\(ring.sourceUnavailableCount)"
                        + " · write-backpressure c/r \(contiguous.destinationBackpressureCount)/\(ring.destinationBackpressureCount)"
                )
                print(
                    "      ring split read/write \(ring.splitRefills)/\(ring.splitDrains)"
                        + " · direct drains c/r \(contiguous.directDrainCount)/\(ring.directDrainCount)"
                )
            }

            print("")
        }

        print("interpretation:")
        print("  correlate ring/contiguous with compacted-bytes/useful-bytes, not chunk size alone.")
        print("  128/256 KiB deliberately test the direct-bypass regime above the 64 KiB buffer.")
        print("  source-unavailable and write-backpressure expose schedule pressure in the local socketpair.")
        print("  this remains a warm local-kernel benchmark; use it to choose storage mechanics, not network latency.")
        print("")
    }
}

private struct RingSocketSweepProfile {
    let chunkSize: Int
    let consumeSize: Int
    let producerBurst: Int
    let receiverBurst: Int
}

private struct RingSocketSweepSample {
    let nanoseconds: UInt64

    let sourceCompactionCalls: UInt64
    let sourceCompactedBytes: UInt64
    let destinationCompactionCalls: UInt64
    let destinationCompactedBytes: UInt64

    let refillCalls: UInt64
    let drainCalls: UInt64
    let sourceUnavailableCount: UInt64
    let destinationBackpressureCount: UInt64

    let splitRefills: UInt64
    let splitDrains: UInt64
    let directDrainCount: UInt64
}

private extension TestIO {
    static func timeContiguousSocketSweep(
        logicalBytes: Int,
        capacity: BufferCapacity,
        profile: RingSocketSweepProfile
    ) throws -> RingSocketSweepSample {
        var descriptors: [Int32] = [0, 0]
        guard makeSweepSocketPair(&descriptors) == 0 else {
            throw TestFailure(message: "contiguous sweep socketpair failed")
        }
        defer {
            closeSweepDescriptor(descriptors[0])
            closeSweepDescriptor(descriptors[1])
        }

        let writerBackend = try NonblockingSocketBackend(
            descriptor: descriptors[0],
            ownsDescriptor: false
        )
        let readerBackend = try NonblockingSocketBackend(
            descriptor: descriptors[1],
            ownsDescriptor: false
        )
        var destination = Destination(
            writerBackend,
            bufferCapacity: capacity
        )
        var source = Source(
            readerBackend,
            bufferCapacity: capacity
        )
        let chunk = Array(repeating: UInt8(0x5A), count: profile.chunkSize)

        var accepted = 0
        var consumed = 0
        var stagnantIterations = 0
        var sourceUnavailableCount: UInt64 = 0
        var destinationBackpressureCount: UInt64 = 0

        let start = DispatchTime.now().uptimeNanoseconds

        while consumed < logicalBytes {
            let beforeAccepted = accepted
            let beforeConsumed = consumed

            for _ in 0..<profile.producerBurst where accepted < logicalBytes {
                let requestCount = min(profile.chunkSize, logicalBytes - accepted)
                let result = try chunk.withUnsafeBytes { raw -> DestinationWrite in
                    let offered = UnsafeRawBufferPointer(
                        start: raw.baseAddress,
                        count: requestCount
                    )
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

            if try destination.flush() == .unavailable {
                destinationBackpressureCount += 1
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

            if accepted == beforeAccepted && consumed == beforeConsumed {
                stagnantIterations += 1
                if stagnantIterations > 100_000 {
                    throw TestFailure(message: "contiguous socket sweep stalled")
                }
            } else {
                stagnantIterations = 0
            }
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let sourceCompaction = source.bufferCompactionStatistics
        let destinationCompaction = destination.bufferCompactionStatistics

        return .init(
            nanoseconds: elapsed,
            sourceCompactionCalls: sourceCompaction.callCount,
            sourceCompactedBytes: sourceCompaction.movedByteCount,
            destinationCompactionCalls: destinationCompaction.callCount,
            destinationCompactedBytes: destinationCompaction.movedByteCount,
            refillCalls: source.statistics.refillCallCount,
            drainCalls: destination.statistics.drainCallCount,
            sourceUnavailableCount: sourceUnavailableCount,
            destinationBackpressureCount: destinationBackpressureCount,
            splitRefills: 0,
            splitDrains: 0,
            directDrainCount: destination.directDrainCount
        )
    }

    static func timeRingSocketSweep(
        logicalBytes: Int,
        capacity: BufferCapacity,
        profile: RingSocketSweepProfile
    ) throws -> RingSocketSweepSample {
        var descriptors: [Int32] = [0, 0]
        guard makeSweepSocketPair(&descriptors) == 0 else {
            throw TestFailure(message: "ring sweep socketpair failed")
        }
        defer {
            closeSweepDescriptor(descriptors[0])
            closeSweepDescriptor(descriptors[1])
        }

        let writerBackend = try NonblockingSocketBackend(
            descriptor: descriptors[0],
            ownsDescriptor: false
        )
        let readerBackend = try NonblockingSocketBackend(
            descriptor: descriptors[1],
            ownsDescriptor: false
        )
        var destination = RingDestination(
            writerBackend,
            bufferCapacity: capacity
        )
        var source = RingSource(
            readerBackend,
            bufferCapacity: capacity
        )
        let chunk = Array(repeating: UInt8(0x5A), count: profile.chunkSize)

        var accepted = 0
        var consumed = 0
        var stagnantIterations = 0
        var sourceUnavailableCount: UInt64 = 0
        var destinationBackpressureCount: UInt64 = 0

        let start = DispatchTime.now().uptimeNanoseconds

        while consumed < logicalBytes {
            let beforeAccepted = accepted
            let beforeConsumed = consumed

            for _ in 0..<profile.producerBurst where accepted < logicalBytes {
                let requestCount = min(profile.chunkSize, logicalBytes - accepted)
                let result = try chunk.withUnsafeBytes { raw -> DestinationWrite in
                    let offered = UnsafeRawBufferPointer(
                        start: raw.baseAddress,
                        count: requestCount
                    )
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

            if try destination.flush() == .unavailable {
                destinationBackpressureCount += 1
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

            if accepted == beforeAccepted && consumed == beforeConsumed {
                stagnantIterations += 1
                if stagnantIterations > 100_000 {
                    throw TestFailure(message: "ring socket sweep stalled")
                }
            } else {
                stagnantIterations = 0
            }
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        return .init(
            nanoseconds: elapsed,
            sourceCompactionCalls: 0,
            sourceCompactedBytes: 0,
            destinationCompactionCalls: 0,
            destinationCompactedBytes: 0,
            refillCalls: source.statistics.refillCallCount,
            drainCalls: destination.statistics.drainCallCount,
            sourceUnavailableCount: sourceUnavailableCount,
            destinationBackpressureCount: destinationBackpressureCount,
            splitRefills: source.splitRefillCount,
            splitDrains: destination.splitDrainCount,
            directDrainCount: destination.directDrainCount
        )
    }

    static func aggregateSweepSamples(
        _ samples: [RingSocketSweepSample]
    ) -> RingSocketSweepSample {
        .init(
            nanoseconds: medianSweep(samples.map(\.nanoseconds)),
            sourceCompactionCalls: medianSweep(samples.map(\.sourceCompactionCalls)),
            sourceCompactedBytes: medianSweep(samples.map(\.sourceCompactedBytes)),
            destinationCompactionCalls: medianSweep(samples.map(\.destinationCompactionCalls)),
            destinationCompactedBytes: medianSweep(samples.map(\.destinationCompactedBytes)),
            refillCalls: medianSweep(samples.map(\.refillCalls)),
            drainCalls: medianSweep(samples.map(\.drainCalls)),
            sourceUnavailableCount: medianSweep(samples.map(\.sourceUnavailableCount)),
            destinationBackpressureCount: medianSweep(samples.map(\.destinationBackpressureCount)),
            splitRefills: medianSweep(samples.map(\.splitRefills)),
            splitDrains: medianSweep(samples.map(\.splitDrains)),
            directDrainCount: medianSweep(samples.map(\.directDrainCount))
        )
    }

    static func medianSweep(
        _ values: [UInt64]
    ) -> UInt64 {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func formatSweepMilliseconds(
        _ nanoseconds: UInt64
    ) -> String {
        String(format: "%.3f ms", Double(nanoseconds) / 1_000_000.0)
    }

    static func formatSweepBytes(
        _ bytes: Int
    ) -> String {
        formatSweepBytes(UInt64(bytes))
    }

    static func formatSweepBytes(
        _ bytes: UInt64
    ) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.2f MiB", Double(bytes) / 1_048_576.0)
        }
        if bytes >= 1024 {
            return String(format: "%.2f KiB", Double(bytes) / 1024.0)
        }
        return "\(bytes) B"
    }

    static func makeSweepSocketPair(
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

    static func closeSweepDescriptor(
        _ descriptor: Int32
    ) {
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #elseif canImport(Glibc)
        _ = Glibc.close(descriptor)
        #endif
    }
}
