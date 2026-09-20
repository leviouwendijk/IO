import Dispatch
import IO
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    static func runRingSocketDecompositionBenchmarks(
        heavy: Bool
    ) throws {
        let capacity = try BufferCapacity(64 * 1024)
        let targetNanoseconds: UInt64 = heavy ? 120_000_000 : 40_000_000
        let rounds = heavy ? 5 : 3
        let initialLogicalBytes = 16 * 1024 * 1024
        let maximumLogicalBytes = 1024 * 1024 * 1024

        let profiles: [RingDecompositionProfile] = [
            .init(
                name: "token-ish 256/192 B",
                chunkSize: 256,
                consumeSize: 192,
                producerBurst: 128,
                receiverBurst: 64
            ),
            .init(
                name: "stream 4/3 KiB",
                chunkSize: 4 * 1024,
                consumeSize: 3 * 1024,
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
            .init(
                name: "boundary 64/48 KiB",
                chunkSize: 64 * 1024,
                consumeSize: 48 * 1024,
                producerBurst: 1,
                receiverBurst: 1
            ),
        ]

        print("ring socket decomposition · nonblocking socketpair")
        print("  source/destination capacity: 64 KiB")
        print("  samples calibrated from contiguous baseline toward \(heavy ? "120+" : "40+") ms")
        print("  \(rounds) interleaved rounds/variant")
        print("  cc = contiguous source + contiguous destination")
        print("  rc = ring source + contiguous destination")
        print("  cr = contiguous source + ring destination")
        print("  rr = ring source + ring destination")
        print("")

        for profile in profiles {
            let logicalBytes = try calibratedDecompositionBytes(
                initialBytes: initialLogicalBytes,
                maximumBytes: maximumLogicalBytes,
                targetNanoseconds: targetNanoseconds,
                chunkSize: profile.chunkSize
            ) { logicalBytes in
                try timeContiguousContiguous(
                    logicalBytes: logicalBytes,
                    capacity: capacity,
                    profile: profile,
                    directBypassPolicy: .larger_than_buffer
                )
            }

            var ccSamples: [RingDecompositionSample] = []
            var rcSamples: [RingDecompositionSample] = []
            var crSamples: [RingDecompositionSample] = []
            var rrSamples: [RingDecompositionSample] = []

            for round in 0..<rounds {
                if round.isMultiple(of: 2) {
                    ccSamples.append(
                        try timeContiguousContiguous(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile,
                            directBypassPolicy: .larger_than_buffer
                        )
                    )
                    rcSamples.append(
                        try timeRingSourceContiguousDestination(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile
                        )
                    )
                    crSamples.append(
                        try timeContiguousSourceRingDestination(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile
                        )
                    )
                    rrSamples.append(
                        try timeRingRing(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile,
                            directBypassPolicy: .larger_than_buffer
                        )
                    )
                } else {
                    rrSamples.append(
                        try timeRingRing(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile,
                            directBypassPolicy: .larger_than_buffer
                        )
                    )
                    crSamples.append(
                        try timeContiguousSourceRingDestination(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile
                        )
                    )
                    rcSamples.append(
                        try timeRingSourceContiguousDestination(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile
                        )
                    )
                    ccSamples.append(
                        try timeContiguousContiguous(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile,
                            directBypassPolicy: .larger_than_buffer
                        )
                    )
                }
            }

            let cc = aggregateDecompositionSamples(ccSamples)
            let rc = aggregateDecompositionSamples(rcSamples)
            let cr = aggregateDecompositionSamples(crSamples)
            let rr = aggregateDecompositionSamples(rrSamples)

            print("\(profile.name) · \(formatDecompositionBytes(logicalBytes)) logical/sample")
            print("  cc \(formatDecompositionTiming(cc)) · baseline")
            print(
                String(
                    format: "  rc %@ · %.3fx · source-only ring",
                    formatDecompositionTiming(rc),
                    Double(rc.nanoseconds) / Double(cc.nanoseconds)
                )
            )
            print(
                String(
                    format: "  cr %@ · %.3fx · destination-only ring",
                    formatDecompositionTiming(cr),
                    Double(cr.nanoseconds) / Double(cc.nanoseconds)
                )
            )
            print(
                String(
                    format: "  rr %@ · %.3fx · both ring",
                    formatDecompositionTiming(rr),
                    Double(rr.nanoseconds) / Double(cc.nanoseconds)
                )
            )
            print(
                "  cc compaction src/dst "
                    + "\(formatDecompositionBytes(cc.sourceCompactedBytes))/"
                    + "\(formatDecompositionBytes(cc.destinationCompactedBytes))"
            )
            print(
                "  rc dest-compaction \(formatDecompositionBytes(rc.destinationCompactedBytes))"
                    + " · split-readv \(rc.splitRefills)"
            )
            print(
                "  cr src-compaction \(formatDecompositionBytes(cr.sourceCompactedBytes))"
                    + " · split-writev \(cr.splitDrains)"
            )
            print(
                "  rr split read/write \(rr.splitRefills)/\(rr.splitDrains)"
                    + " · direct drains \(rr.directDrainCount)"
            )
            print("")
        }

        print("exact-capacity destination bypass · 64 KiB caller span")
        print("  >  = current production policy; exact-capacity write stages locally")
        print("  >= = experiment; exact-capacity write is offered directly")
        print("")

        let exactConsumeSizes: [(String, Int)] = [
            ("25%", 16 * 1024),
            ("50%", 32 * 1024),
            ("75%", 48 * 1024),
            ("100%", 64 * 1024),
        ]

        for (label, consumeSize) in exactConsumeSizes {
            let profile = RingDecompositionProfile(
                name: "exact-capacity \(label)",
                chunkSize: 64 * 1024,
                consumeSize: consumeSize,
                producerBurst: 1,
                receiverBurst: 1
            )

            let logicalBytes = try calibratedDecompositionBytes(
                initialBytes: initialLogicalBytes,
                maximumBytes: maximumLogicalBytes,
                targetNanoseconds: targetNanoseconds,
                chunkSize: profile.chunkSize
            ) { logicalBytes in
                try timeContiguousContiguous(
                    logicalBytes: logicalBytes,
                    capacity: capacity,
                    profile: profile,
                    directBypassPolicy: .larger_than_buffer
                )
            }

            var contiguousGreater: [RingDecompositionSample] = []
            var contiguousAtLeast: [RingDecompositionSample] = []
            var ringGreater: [RingDecompositionSample] = []
            var ringAtLeast: [RingDecompositionSample] = []

            for round in 0..<rounds {
                if round.isMultiple(of: 2) {
                    contiguousGreater.append(
                        try timeContiguousContiguous(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile,
                            directBypassPolicy: .larger_than_buffer
                        )
                    )
                    contiguousAtLeast.append(
                        try timeContiguousContiguous(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile,
                            directBypassPolicy: .at_least_buffer
                        )
                    )
                    ringGreater.append(
                        try timeRingRing(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile,
                            directBypassPolicy: .larger_than_buffer
                        )
                    )
                    ringAtLeast.append(
                        try timeRingRing(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile,
                            directBypassPolicy: .at_least_buffer
                        )
                    )
                } else {
                    ringAtLeast.append(
                        try timeRingRing(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile,
                            directBypassPolicy: .at_least_buffer
                        )
                    )
                    ringGreater.append(
                        try timeRingRing(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile,
                            directBypassPolicy: .larger_than_buffer
                        )
                    )
                    contiguousAtLeast.append(
                        try timeContiguousContiguous(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile,
                            directBypassPolicy: .at_least_buffer
                        )
                    )
                    contiguousGreater.append(
                        try timeContiguousContiguous(
                            logicalBytes: logicalBytes,
                            capacity: capacity,
                            profile: profile,
                            directBypassPolicy: .larger_than_buffer
                        )
                    )
                }
            }

            let cgt = aggregateDecompositionSamples(contiguousGreater)
            let cge = aggregateDecompositionSamples(contiguousAtLeast)
            let rgt = aggregateDecompositionSamples(ringGreater)
            let rge = aggregateDecompositionSamples(ringAtLeast)

            print("\(label) consume \(formatDecompositionBytes(consumeSize)) · \(formatDecompositionBytes(logicalBytes)) logical/sample")
            print(
                String(
                    format: "  contiguous >  %@ · direct %llu · dst-move %@",
                    formatDecompositionTiming(cgt),
                    cgt.directDrainCount,
                    formatDecompositionBytes(cgt.destinationCompactedBytes)
                )
            )
            print(
                String(
                    format: "  contiguous >= %@ · %.3fx vs > · direct %llu · dst-move %@",
                    formatDecompositionTiming(cge),
                    Double(cge.nanoseconds) / Double(cgt.nanoseconds),
                    cge.directDrainCount,
                    formatDecompositionBytes(cge.destinationCompactedBytes)
                )
            )
            print(
                String(
                    format: "  ring >        %@ · direct %llu · split-write %llu",
                    formatDecompositionTiming(rgt),
                    rgt.directDrainCount,
                    rgt.splitDrains
                )
            )
            print(
                String(
                    format: "  ring >=       %@ · %.3fx vs > · direct %llu · split-write %llu",
                    formatDecompositionTiming(rge),
                    Double(rge.nanoseconds) / Double(rgt.nanoseconds),
                    rge.directDrainCount,
                    rge.splitDrains
                )
            )
            print("")
        }

        print("guardrails:")
        print("  production Destination/RingDestination still default to > capacity bypass.")
        print("  >= is package-only experimental policy for this benchmark.")
        print("  decomposition changes one storage side at a time; use it to attribute source vs destination cost.")
        print("  calibrated samples reduce short-run scheduler noise but socketpair remains warm local-kernel I/O.")
        print("")
    }
}

private struct RingDecompositionProfile {
    let name: String
    let chunkSize: Int
    let consumeSize: Int
    let producerBurst: Int
    let receiverBurst: Int
}

private struct RingDecompositionSample {
    let nanoseconds: UInt64
    let sourceCompactedBytes: UInt64
    let destinationCompactedBytes: UInt64
    let refillCalls: UInt64
    let drainCalls: UInt64
    let sourceUnavailableCount: UInt64
    let destinationBackpressureCount: UInt64
    let splitRefills: UInt64
    let splitDrains: UInt64
    let directDrainCount: UInt64
}

private struct RingDecompositionAggregate {
    let minimumNanoseconds: UInt64
    let nanoseconds: UInt64
    let maximumNanoseconds: UInt64
    let sourceCompactedBytes: UInt64
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
    static func calibratedDecompositionBytes(
        initialBytes: Int,
        maximumBytes: Int,
        targetNanoseconds: UInt64,
        chunkSize: Int,
        measure: (Int) throws -> RingDecompositionSample
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
        let raw = max(initialBytes, Int(requested.rounded(.up)))
        let rounded = ((raw + chunkSize - 1) / chunkSize) * chunkSize
        return min(maximumBytes, rounded)
    }

    static func timeContiguousContiguous(
        logicalBytes: Int,
        capacity: BufferCapacity,
        profile: RingDecompositionProfile,
        directBypassPolicy: DestinationDirectBypassPolicy
    ) throws -> RingDecompositionSample {
        var descriptors: [Int32] = [0, 0]
        guard makeDecompositionSocketPair(&descriptors) == 0 else {
            throw TestFailure(message: "cc decomposition socketpair failed")
        }
        defer {
            closeDecompositionDescriptor(descriptors[0])
            closeDecompositionDescriptor(descriptors[1])
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
            bufferCapacity: capacity,
            directBypassPolicy: directBypassPolicy
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

            try checkDecompositionProgress(
                accepted: accepted,
                consumed: consumed,
                beforeAccepted: beforeAccepted,
                beforeConsumed: beforeConsumed,
                stagnantIterations: &stagnantIterations,
                label: "cc"
            )
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        return .init(
            nanoseconds: elapsed,
            sourceCompactedBytes: source.bufferCompactionStatistics.movedByteCount,
            destinationCompactedBytes: destination.bufferCompactionStatistics.movedByteCount,
            refillCalls: source.statistics.refillCallCount,
            drainCalls: destination.statistics.drainCallCount,
            sourceUnavailableCount: sourceUnavailableCount,
            destinationBackpressureCount: destinationBackpressureCount,
            splitRefills: 0,
            splitDrains: 0,
            directDrainCount: destination.directDrainCount
        )
    }

    static func timeRingSourceContiguousDestination(
        logicalBytes: Int,
        capacity: BufferCapacity,
        profile: RingDecompositionProfile
    ) throws -> RingDecompositionSample {
        var descriptors: [Int32] = [0, 0]
        guard makeDecompositionSocketPair(&descriptors) == 0 else {
            throw TestFailure(message: "rc decomposition socketpair failed")
        }
        defer {
            closeDecompositionDescriptor(descriptors[0])
            closeDecompositionDescriptor(descriptors[1])
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

            try checkDecompositionProgress(
                accepted: accepted,
                consumed: consumed,
                beforeAccepted: beforeAccepted,
                beforeConsumed: beforeConsumed,
                stagnantIterations: &stagnantIterations,
                label: "rc"
            )
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        return .init(
            nanoseconds: elapsed,
            sourceCompactedBytes: 0,
            destinationCompactedBytes: destination.bufferCompactionStatistics.movedByteCount,
            refillCalls: source.statistics.refillCallCount,
            drainCalls: destination.statistics.drainCallCount,
            sourceUnavailableCount: sourceUnavailableCount,
            destinationBackpressureCount: destinationBackpressureCount,
            splitRefills: source.splitRefillCount,
            splitDrains: 0,
            directDrainCount: destination.directDrainCount
        )
    }

    static func timeContiguousSourceRingDestination(
        logicalBytes: Int,
        capacity: BufferCapacity,
        profile: RingDecompositionProfile
    ) throws -> RingDecompositionSample {
        var descriptors: [Int32] = [0, 0]
        guard makeDecompositionSocketPair(&descriptors) == 0 else {
            throw TestFailure(message: "cr decomposition socketpair failed")
        }
        defer {
            closeDecompositionDescriptor(descriptors[0])
            closeDecompositionDescriptor(descriptors[1])
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

            try checkDecompositionProgress(
                accepted: accepted,
                consumed: consumed,
                beforeAccepted: beforeAccepted,
                beforeConsumed: beforeConsumed,
                stagnantIterations: &stagnantIterations,
                label: "cr"
            )
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        return .init(
            nanoseconds: elapsed,
            sourceCompactedBytes: source.bufferCompactionStatistics.movedByteCount,
            destinationCompactedBytes: 0,
            refillCalls: source.statistics.refillCallCount,
            drainCalls: destination.statistics.drainCallCount,
            sourceUnavailableCount: sourceUnavailableCount,
            destinationBackpressureCount: destinationBackpressureCount,
            splitRefills: 0,
            splitDrains: destination.splitDrainCount,
            directDrainCount: destination.directDrainCount
        )
    }

    static func timeRingRing(
        logicalBytes: Int,
        capacity: BufferCapacity,
        profile: RingDecompositionProfile,
        directBypassPolicy: DestinationDirectBypassPolicy
    ) throws -> RingDecompositionSample {
        var descriptors: [Int32] = [0, 0]
        guard makeDecompositionSocketPair(&descriptors) == 0 else {
            throw TestFailure(message: "rr decomposition socketpair failed")
        }
        defer {
            closeDecompositionDescriptor(descriptors[0])
            closeDecompositionDescriptor(descriptors[1])
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
            bufferCapacity: capacity,
            directBypassPolicy: directBypassPolicy
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

            try checkDecompositionProgress(
                accepted: accepted,
                consumed: consumed,
                beforeAccepted: beforeAccepted,
                beforeConsumed: beforeConsumed,
                stagnantIterations: &stagnantIterations,
                label: "rr"
            )
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        return .init(
            nanoseconds: elapsed,
            sourceCompactedBytes: 0,
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

    static func checkDecompositionProgress(
        accepted: Int,
        consumed: Int,
        beforeAccepted: Int,
        beforeConsumed: Int,
        stagnantIterations: inout Int,
        label: String
    ) throws {
        if accepted == beforeAccepted && consumed == beforeConsumed {
            stagnantIterations += 1
            if stagnantIterations > 100_000 {
                throw TestFailure(message: "\(label) decomposition benchmark stalled")
            }
        } else {
            stagnantIterations = 0
        }
    }

    static func aggregateDecompositionSamples(
        _ samples: [RingDecompositionSample]
    ) -> RingDecompositionAggregate {
        let times = samples.map(\.nanoseconds).sorted()
        return .init(
            minimumNanoseconds: times.first ?? 0,
            nanoseconds: times[times.count / 2],
            maximumNanoseconds: times.last ?? 0,
            sourceCompactedBytes: medianDecomposition(samples.map(\.sourceCompactedBytes)),
            destinationCompactedBytes: medianDecomposition(samples.map(\.destinationCompactedBytes)),
            refillCalls: medianDecomposition(samples.map(\.refillCalls)),
            drainCalls: medianDecomposition(samples.map(\.drainCalls)),
            sourceUnavailableCount: medianDecomposition(samples.map(\.sourceUnavailableCount)),
            destinationBackpressureCount: medianDecomposition(samples.map(\.destinationBackpressureCount)),
            splitRefills: medianDecomposition(samples.map(\.splitRefills)),
            splitDrains: medianDecomposition(samples.map(\.splitDrains)),
            directDrainCount: medianDecomposition(samples.map(\.directDrainCount))
        )
    }

    static func medianDecomposition(
        _ values: [UInt64]
    ) -> UInt64 {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func formatDecompositionTiming(
        _ aggregate: RingDecompositionAggregate
    ) -> String {
        "\(formatDecompositionMilliseconds(aggregate.nanoseconds)) "
            + "[\(formatDecompositionMilliseconds(aggregate.minimumNanoseconds))"
            + "…\(formatDecompositionMilliseconds(aggregate.maximumNanoseconds))]"
    }

    static func formatDecompositionMilliseconds(
        _ nanoseconds: UInt64
    ) -> String {
        String(format: "%.3f ms", Double(nanoseconds) / 1_000_000.0)
    }

    static func formatDecompositionBytes(
        _ bytes: Int
    ) -> String {
        formatDecompositionBytes(UInt64(bytes))
    }

    static func formatDecompositionBytes(
        _ bytes: UInt64
    ) -> String {
        if bytes >= 1024 * 1024 {
            return String(
                format: "%.2f MiB",
                Double(bytes) / Double(1024 * 1024)
            )
        }
        if bytes >= 1024 {
            return String(
                format: "%.2f KiB",
                Double(bytes) / 1024.0
            )
        }
        return "\(bytes) B"
    }

    static func makeDecompositionSocketPair(
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

    static func closeDecompositionDescriptor(
        _ descriptor: Int32
    ) {
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #elseif canImport(Glibc)
        _ = Glibc.close(descriptor)
        #endif
    }
}
