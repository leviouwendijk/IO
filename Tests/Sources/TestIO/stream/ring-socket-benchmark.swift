import Dispatch
import IO
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    static func runRingSocketBenchmarks(
        heavy: Bool
    ) throws {
        let logicalBytes = heavy
            ? 64 * 1024 * 1024
            : 16 * 1024 * 1024
        let rounds = heavy ? 9 : 5
        let capacity = try BufferCapacity(64 * 1024)

        let profiles: [RingSocketProfile] = [
            .init(
                name: "token-ish 256/192 B",
                chunkSize: 256,
                consumeSize: 192,
                producerBurst: 128,
                receiverBurst: 64
            ),
            .init(
                name: "stream 4/3 KiB",
                chunkSize: 4096,
                consumeSize: 3072,
                producerBurst: 32,
                receiverBurst: 32
            ),
            .init(
                name: "body 16/12 KiB",
                chunkSize: 16 * 1024,
                consumeSize: 12 * 1024,
                producerBurst: 16,
                receiverBurst: 16
            ),
        ]

        print("ring socket stream experiment · nonblocking socketpair")
        print("  logical bytes/profile/sample: \(formatRingBytes(UInt64(logicalBytes)))")
        print("  source/destination capacity: 64 KiB")
        print("  \(rounds) interleaved rounds")
        print("  contiguous = production Source/Destination + recv/send + memmove compaction")
        print("  ring       = experimental RingSource/RingDestination + readv/writev + no compaction")
        print("")

        for profile in profiles {
            var contiguousTimes: [UInt64] = []
            var ringTimes: [UInt64] = []
            var splitRefills: UInt64 = 0
            var splitDrains: UInt64 = 0

            for round in 0..<rounds {
                if round.isMultiple(of: 2) {
                    contiguousTimes.append(
                        try timeContiguousSocketStream(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile
                        )
                    )
                    let ring = try timeRingSocketStream(
                        logicalBytes: logicalBytes,
                        capacity: capacity,
                        profile: profile
                    )
                    ringTimes.append(ring.nanoseconds)
                    splitRefills = max(splitRefills, ring.splitRefills)
                    splitDrains = max(splitDrains, ring.splitDrains)
                } else {
                    let ring = try timeRingSocketStream(
                        logicalBytes: logicalBytes,
                        capacity: capacity,
                        profile: profile
                    )
                    ringTimes.append(ring.nanoseconds)
                    splitRefills = max(splitRefills, ring.splitRefills)
                    splitDrains = max(splitDrains, ring.splitDrains)
                    contiguousTimes.append(
                        try timeContiguousSocketStream(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile
                        )
                    )
                }
            }

            let contiguous = ringTiming(contiguousTimes)
            let ring = ringTiming(ringTimes)

            print(profile.name)
            print("  contiguous \(formatRingTiming(contiguous))")
            print("  ring       \(formatRingTiming(ring))")
            print(
                String(
                    format: "  ring/contiguous %.3fx",
                    Double(ring.median) / Double(contiguous.median)
                )
            )
            print("  ring split readv refills: \(splitRefills)")
            print("  ring split writev drains: \(splitDrains)")
            print("")
        }

        print("guardrails:")
        print("  socketpair is warm local kernel I/O, not network latency.")
        print("  choose storage policy from whole-stream rows, not the prior buffer-only 18x result.")
        print("  split counts prove whether wrapped two-region readv/writev paths were exercised.")
        print("")
    }
}

private struct RingSocketProfile {
    let name: String
    let chunkSize: Int
    let consumeSize: Int
    let producerBurst: Int
    let receiverBurst: Int
}

private struct RingSocketSample {
    let nanoseconds: UInt64
    let splitRefills: UInt64
    let splitDrains: UInt64
}

private struct RingSocketTiming {
    let minimum: UInt64
    let median: UInt64
    let maximum: UInt64
}

private extension TestIO {
    static func timeContiguousSocketStream(
        logicalBytes: Int,
        capacity: BufferCapacity,
        profile: RingSocketProfile
    ) throws -> UInt64 {
        var descriptors: [Int32] = [0, 0]
        guard makeRingSocketPair(&descriptors) == 0 else {
            throw TestFailure(message: "contiguous benchmark socketpair failed")
        }
        defer {
            closeRingDescriptor(descriptors[0])
            closeRingDescriptor(descriptors[1])
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
                case .unavailable:
                    break
                }

                if result == .unavailable {
                    break
                }
            }

            _ = try destination.flush()

            for _ in 0..<profile.receiverBurst where consumed < logicalBytes {
                let availability = try source.requestMore()
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
                    throw TestFailure(message: "contiguous socket benchmark stalled")
                }
            } else {
                stagnantIterations = 0
            }
        }

        return DispatchTime.now().uptimeNanoseconds - start
    }

    static func timeRingSocketStream(
        logicalBytes: Int,
        capacity: BufferCapacity,
        profile: RingSocketProfile
    ) throws -> RingSocketSample {
        var descriptors: [Int32] = [0, 0]
        guard makeRingSocketPair(&descriptors) == 0 else {
            throw TestFailure(message: "ring benchmark socketpair failed")
        }
        defer {
            closeRingDescriptor(descriptors[0])
            closeRingDescriptor(descriptors[1])
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
                case .unavailable:
                    break
                }

                if result == .unavailable {
                    break
                }
            }

            _ = try destination.flush()

            for _ in 0..<profile.receiverBurst where consumed < logicalBytes {
                let availability = try source.requestMore()
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
                    throw TestFailure(message: "ring socket benchmark stalled")
                }
            } else {
                stagnantIterations = 0
            }
        }

        return .init(
            nanoseconds: DispatchTime.now().uptimeNanoseconds - start,
            splitRefills: source.splitRefillCount,
            splitDrains: destination.splitDrainCount
        )
    }

    static func ringTiming(
        _ values: [UInt64]
    ) -> RingSocketTiming {
        let sorted = values.sorted()
        return .init(
            minimum: sorted.first ?? 0,
            median: sorted[sorted.count / 2],
            maximum: sorted.last ?? 0
        )
    }

    static func formatRingTiming(
        _ timing: RingSocketTiming
    ) -> String {
        "\(formatRingMilliseconds(timing.median)) [\(formatRingMilliseconds(timing.minimum))…\(formatRingMilliseconds(timing.maximum))]"
    }

    static func formatRingMilliseconds(
        _ nanoseconds: UInt64
    ) -> String {
        String(format: "%.3f ms", Double(nanoseconds) / 1_000_000.0)
    }

    static func formatRingBytes(
        _ bytes: UInt64
    ) -> String {
        String(format: "%.2f MiB", Double(bytes) / 1_048_576.0)
    }

    static func makeRingSocketPair(
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

    static func closeRingDescriptor(
        _ descriptor: Int32
    ) {
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #elseif canImport(Glibc)
        _ = Glibc.close(descriptor)
        #endif
    }
}
