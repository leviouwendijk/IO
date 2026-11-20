import Dispatch
import Foundation
import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private enum ProductionRingLane: String, CaseIterable {
    case production_erased
    case generic_ring
}

private struct ProductionRingSample {
    let nanoseconds: UInt64
    let transferredBytes: UInt64
    let boundaryCalls: UInt64
    let splitCalls: UInt64
    let unavailableCount: UInt64
}

private struct ProductionRingAggregate {
    let minimumNanoseconds: UInt64
    let medianNanoseconds: UInt64
    let maximumNanoseconds: UInt64
    let boundaryCalls: UInt64
    let splitCalls: UInt64
    let unavailableCount: UInt64
}

private protocol ProductionRingSourceDriver: ~Copyable {
    var bufferedByteCount: Int { get }
    var refillCallCount: UInt64 { get }
    var refilledByteCount: UInt64 { get }
    var splitRefillCount: UInt64 { get }

    mutating func requestMore() throws -> SourceAvailability
    mutating func consume(_ count: Int) throws
}

private struct ProductionRingErasedSource:
    ProductionRingSourceDriver,
    ~Copyable
{
    private var source: Source

    init<Backend: SourceBackend & ~Copyable>(
        _ backend: consuming Backend,
        capacity: BufferCapacity
    ) {
        source =
            Source(
                consume backend,
                bufferCapacity: capacity
            )
    }

    var bufferedByteCount: Int {
        source.bufferedByteCount
    }

    var refillCallCount: UInt64 {
        source.statistics.refillCallCount
    }

    var refilledByteCount: UInt64 {
        source.statistics.refilledByteCount
    }

    var splitRefillCount: UInt64 {
        source.splitRefillCount
    }

    mutating func requestMore() throws -> SourceAvailability {
        try source.requestMore()
    }

    mutating func consume(_ count: Int) throws {
        try source.consume(count)
    }
}

private struct ProductionRingGenericSource<
    Backend: SourceBackend & ~Copyable
>:
    ProductionRingSourceDriver,
    ~Copyable
{
    private var source: RingSource<Backend>

    init(
        _ backend: consuming Backend,
        capacity: BufferCapacity
    ) {
        source =
            RingSource(
                consume backend,
                bufferCapacity: capacity
            )
    }

    var bufferedByteCount: Int {
        source.bufferedByteCount
    }

    var refillCallCount: UInt64 {
        source.statistics.refillCallCount
    }

    var refilledByteCount: UInt64 {
        source.statistics.refilledByteCount
    }

    var splitRefillCount: UInt64 {
        source.splitRefillCount
    }

    mutating func requestMore() throws -> SourceAvailability {
        try source.requestMore()
    }

    mutating func consume(_ count: Int) throws {
        try source.consume(count)
    }
}

private protocol ProductionRingDestinationDriver: ~Copyable {
    var bufferedByteCount: Int { get }
    var drainCallCount: UInt64 { get }
    var drainedByteCount: UInt64 { get }
    var splitDrainCount: UInt64 { get }

    mutating func write(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationWrite

    mutating func flush() throws -> DestinationFlush
}

private struct ProductionRingErasedDestination:
    ProductionRingDestinationDriver,
    ~Copyable
{
    private var destination: Destination

    init<Backend: DestinationBackend & ~Copyable>(
        _ backend: consuming Backend,
        capacity: BufferCapacity
    ) {
        destination =
            Destination(
                consume backend,
                bufferCapacity: capacity
            )
    }

    var bufferedByteCount: Int {
        destination.bufferedByteCount
    }

    var drainCallCount: UInt64 {
        destination.statistics.drainCallCount
    }

    var drainedByteCount: UInt64 {
        destination.statistics.drainedByteCount
    }

    var splitDrainCount: UInt64 {
        destination.splitDrainCount
    }

    mutating func write(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationWrite {
        try destination.write(bytes)
    }

    mutating func flush() throws -> DestinationFlush {
        try destination.flush()
    }
}

private struct ProductionRingGenericDestination<
    Backend: DestinationBackend & ~Copyable
>:
    ProductionRingDestinationDriver,
    ~Copyable
{
    private var destination: RingDestination<Backend>

    init(
        _ backend: consuming Backend,
        capacity: BufferCapacity
    ) {
        destination =
            RingDestination(
                consume backend,
                bufferCapacity: capacity
            )
    }

    var bufferedByteCount: Int {
        destination.bufferedByteCount
    }

    var drainCallCount: UInt64 {
        destination.statistics.drainCallCount
    }

    var drainedByteCount: UInt64 {
        destination.statistics.drainedByteCount
    }

    var splitDrainCount: UInt64 {
        destination.splitDrainCount
    }

    mutating func write(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationWrite {
        try destination.write(bytes)
    }

    mutating func flush() throws -> DestinationFlush {
        try destination.flush()
    }
}

extension TestIO {
    static func runProductionRingGenericBenchmarks(
        heavy: Bool
    ) throws {
        let capacityBytes =
            64 * 1024
        let capacity =
            try BufferCapacity(
                capacityBytes
            )
        let fileBytes =
            heavy
                ? 256 * 1024 * 1024
                : 64 * 1024 * 1024
        let destinationBytes =
            heavy
                ? 512 * 1024 * 1024
                : 128 * 1024 * 1024
        let socketBytes =
            heavy
                ? 256 * 1024 * 1024
                : 64 * 1024 * 1024
        let samples =
            heavy
                ? 7
                : 5
        let sourceConsumeSize =
            48 * 1024
        let writeChunkSize =
            48 * 1024

        let root =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "io-production-ring-generic-\(UUID().uuidString)",
                    isDirectory: true
                )
        let sourceFile =
            root.appendingPathComponent(
                "source.bin"
            )

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: root
            )
        }

        try prepareProductionRingSourceFile(
            sourceFile,
            byteCount: fileBytes
        )

        print("production ring generic retention")
        print("  A = actual production Source/Destination (any Backend)")
        print("  G = identical generic RingSource/RingDestination (concrete Backend)")
        print("  ring capacity: \(formatProductionRingBytes(capacityBytes))")
        print("  write/consume chunk: \(formatProductionRingBytes(writeChunkSize))")
        print("  endpoint construction/open/socketpair timed: false")
        print("  samples per lane: \(samples)")
        print("")

        let fileSource =
            try collectProductionRingSamples(
                samples: samples,
                requireDeterministicBoundaryWork: true,
                expectedBytes: fileBytes,
                production: {
                    let backend =
                        try SystemFileSource(
                            path: sourceFile.path
                        )
                    return try timeProductionRingSource(
                        source:
                            ProductionRingErasedSource(
                                backend,
                                capacity: capacity
                            ),
                        logicalBytes: fileBytes,
                        consumeSize: sourceConsumeSize,
                        label: "system file source A"
                    )
                },
                generic: {
                    let backend =
                        try SystemFileSource(
                            path: sourceFile.path
                        )
                    return try timeProductionRingSource(
                        source:
                            ProductionRingGenericSource(
                                backend,
                                capacity: capacity
                            ),
                        logicalBytes: fileBytes,
                        consumeSize: sourceConsumeSize,
                        label: "system file source G"
                    )
                }
            )

        printProductionRingRow(
            label:
                "SystemFileSource · cached regular file · \(formatProductionRingBytes(fileBytes))",
            aggregates: fileSource
        )

        let fileDestination =
            try collectProductionRingSamples(
                samples: samples,
                requireDeterministicBoundaryWork: true,
                expectedBytes: destinationBytes,
                production: {
                    let backend =
                        try SystemFileDestination(
                            path: "/dev/null",
                            mode: .append
                        )
                    return try timeProductionRingDestination(
                        destination:
                            ProductionRingErasedDestination(
                                backend,
                                capacity: capacity
                            ),
                        logicalBytes: destinationBytes,
                        chunkSize: writeChunkSize,
                        label: "system file destination A"
                    )
                },
                generic: {
                    let backend =
                        try SystemFileDestination(
                            path: "/dev/null",
                            mode: .append
                        )
                    return try timeProductionRingDestination(
                        destination:
                            ProductionRingGenericDestination(
                                backend,
                                capacity: capacity
                            ),
                        logicalBytes: destinationBytes,
                        chunkSize: writeChunkSize,
                        label: "system file destination G"
                    )
                }
            )

        printProductionRingRow(
            label:
                "SystemFileDestination · /dev/null · \(formatProductionRingBytes(destinationBytes))",
            aggregates: fileDestination
        )

        let socket =
            try collectProductionRingSamples(
                samples: samples,
                requireDeterministicBoundaryWork: false,
                expectedBytes: socketBytes,
                production: {
                    try timeProductionRingSocket(
                        lane: .production_erased,
                        logicalBytes: socketBytes,
                        capacity: capacity,
                        chunkSize: writeChunkSize,
                        consumeSize: sourceConsumeSize
                    )
                },
                generic: {
                    try timeProductionRingSocket(
                        lane: .generic_ring,
                        logicalBytes: socketBytes,
                        capacity: capacity,
                        chunkSize: writeChunkSize,
                        consumeSize: sourceConsumeSize
                    )
                }
            )

        printProductionRingRow(
            label:
                "NonblockingSocketBackend · composed socketpair · \(formatProductionRingBytes(socketBytes))",
            aggregates: socket
        )

        print("interpretation:")
        print("  G consistently and materially faster across real endpoints -> consider retaining Backend generically in production.")
        print("  G advantage only at synthetic/raw boundaries, not here -> keep production existential erasure.")
        print("  socket call/backpressure counts are diagnostics, not equality constraints, because kernel pacing is timing-sensitive.")
    }
}

private extension TestIO {
    static func prepareProductionRingSourceFile(
        _ url: URL,
        byteCount: Int
    ) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil
        ) else {
            throw TestFailure(
                message:
                    "production-ring benchmark could not create source fixture"
            )
        }

        let handle =
            try FileHandle(
                forWritingTo: url
            )
        defer {
            try? handle.close()
        }

        let chunkSize =
            1024 * 1024
        let chunk =
            Data(
                repeating: 0x5a,
                count: chunkSize
            )

        var written = 0
        while written < byteCount {
            let count =
                min(
                    chunkSize,
                    byteCount - written
                )

            if count == chunkSize {
                try handle.write(
                    contentsOf: chunk
                )
            } else {
                try handle.write(
                    contentsOf:
                        Data(
                            repeating: 0x5a,
                            count: count
                        )
                )
            }

            written += count
        }
    }

    @inline(__always)
    static func timeProductionRingSource<
        Driver: ProductionRingSourceDriver & ~Copyable
    >(
        source initialSource: consuming Driver,
        logicalBytes: Int,
        consumeSize: Int,
        label: String
    ) throws -> ProductionRingSample {
        var source =
            consume initialSource
        var consumed = 0
        var unavailable: UInt64 = 0
        var stagnant = 0

        let start =
            DispatchTime.now().uptimeNanoseconds

        while consumed < logicalBytes {
            let before =
                consumed
            let availability =
                try source.requestMore()

            if availability == .unavailable {
                unavailable += 1
            }

            if source.bufferedByteCount > 0 {
                let count =
                    min(
                        consumeSize,
                        min(
                            source.bufferedByteCount,
                            logicalBytes - consumed
                        )
                    )
                try source.consume(
                    count
                )
                consumed +=
                    count
            }

            if availability == .end,
               consumed < logicalBytes
            {
                throw TestFailure(
                    message:
                        "\(label) reached end before requested bytes"
                )
            }

            if consumed == before {
                stagnant += 1
                if stagnant > 1_000_000 {
                    throw TestFailure(
                        message:
                            "\(label) stalled"
                    )
                }
            } else {
                stagnant = 0
            }
        }

        let elapsed =
            DispatchTime.now().uptimeNanoseconds
            - start

        guard source.refilledByteCount
                == UInt64(logicalBytes)
        else {
            throw TestFailure(
                message:
                    "\(label) refilled byte count mismatch"
            )
        }

        return .init(
            nanoseconds: elapsed,
            transferredBytes: UInt64(consumed),
            boundaryCalls:
                source.refillCallCount,
            splitCalls:
                source.splitRefillCount,
            unavailableCount:
                unavailable
        )
    }

    @inline(__always)
    static func timeProductionRingDestination<
        Driver: ProductionRingDestinationDriver & ~Copyable
    >(
        destination initialDestination: consuming Driver,
        logicalBytes: Int,
        chunkSize: Int,
        label: String
    ) throws -> ProductionRingSample {
        var destination =
            consume initialDestination
        let chunk =
            [UInt8](
                repeating: 0x5a,
                count: chunkSize
            )
        var accepted = 0
        var unavailable: UInt64 = 0
        var stagnant = 0

        let start =
            DispatchTime.now().uptimeNanoseconds

        while accepted < logicalBytes {
            let before =
                accepted
            let requestCount =
                min(
                    chunkSize,
                    logicalBytes - accepted
                )

            let result =
                try chunk.withUnsafeBytes {
                    raw -> DestinationWrite in

                    try destination.write(
                        UnsafeRawBufferPointer(
                            start:
                                raw.baseAddress,
                            count:
                                requestCount
                        )
                    )
                }

            switch result {
            case .complete:
                accepted +=
                    requestCount

            case .partial(let count):
                accepted +=
                    count.value
                unavailable += 1

            case .unavailable:
                unavailable += 1
            }

            if accepted == before {
                stagnant += 1
                if stagnant > 1_000_000 {
                    throw TestFailure(
                        message:
                            "\(label) stalled"
                    )
                }
            } else {
                stagnant = 0
            }
        }

        while destination.bufferedByteCount > 0 {
            if try destination.flush()
                == .unavailable
            {
                unavailable += 1
            }
        }

        let elapsed =
            DispatchTime.now().uptimeNanoseconds
            - start

        guard destination.drainedByteCount
                == UInt64(logicalBytes)
        else {
            throw TestFailure(
                message:
                    "\(label) drained byte count mismatch"
            )
        }

        return .init(
            nanoseconds: elapsed,
            transferredBytes: UInt64(accepted),
            boundaryCalls:
                destination.drainCallCount,
            splitCalls:
                destination.splitDrainCount,
            unavailableCount:
                unavailable
        )
    }

    static func timeProductionRingSocket(
        lane: ProductionRingLane,
        logicalBytes: Int,
        capacity: BufferCapacity,
        chunkSize: Int,
        consumeSize: Int
    ) throws -> ProductionRingSample {
        var descriptors =
            [Int32](
                repeating: -1,
                count: 2
            )

        guard makeProductionRingSocketPair(
            &descriptors
        ) == 0 else {
            throw TestFailure(
                message:
                    "production-ring socketpair failed"
            )
        }

        let destinationBackend =
            try NonblockingSocketBackend(
                descriptor:
                    descriptors[0]
            )
        let sourceBackend =
            try NonblockingSocketBackend(
                descriptor:
                    descriptors[1]
            )

        switch lane {
        case .production_erased:
            return try timeProductionRingComposed(
                source:
                    ProductionRingErasedSource(
                        sourceBackend,
                        capacity: capacity
                    ),
                destination:
                    ProductionRingErasedDestination(
                        destinationBackend,
                        capacity: capacity
                    ),
                logicalBytes: logicalBytes,
                chunkSize: chunkSize,
                consumeSize: consumeSize,
                label: "socket production"
            )

        case .generic_ring:
            return try timeProductionRingComposed(
                source:
                    ProductionRingGenericSource(
                        sourceBackend,
                        capacity: capacity
                    ),
                destination:
                    ProductionRingGenericDestination(
                        destinationBackend,
                        capacity: capacity
                    ),
                logicalBytes: logicalBytes,
                chunkSize: chunkSize,
                consumeSize: consumeSize,
                label: "socket generic"
            )
        }
    }

    @inline(__always)
    static func timeProductionRingComposed<
        SourceDriver:
            ProductionRingSourceDriver & ~Copyable,
        DestinationDriver:
            ProductionRingDestinationDriver & ~Copyable
    >(
        source initialSource: consuming SourceDriver,
        destination initialDestination: consuming DestinationDriver,
        logicalBytes: Int,
        chunkSize: Int,
        consumeSize: Int,
        label: String
    ) throws -> ProductionRingSample {
        var source =
            consume initialSource
        var destination =
            consume initialDestination
        let chunk =
            [UInt8](
                repeating: 0x5a,
                count: chunkSize
            )

        var accepted = 0
        var consumed = 0
        var unavailable: UInt64 = 0
        var stagnant = 0

        let start =
            DispatchTime.now().uptimeNanoseconds

        while accepted < logicalBytes
            || consumed < logicalBytes
            || destination.bufferedByteCount > 0
        {
            let beforeAccepted =
                accepted
            let beforeConsumed =
                consumed
            let beforeBuffered =
                destination.bufferedByteCount

            for _ in 0..<4
            where accepted < logicalBytes
            {
                let requestCount =
                    min(
                        chunkSize,
                        logicalBytes - accepted
                    )

                let result =
                    try chunk.withUnsafeBytes {
                        raw -> DestinationWrite in

                        try destination.write(
                            UnsafeRawBufferPointer(
                                start:
                                    raw.baseAddress,
                                count:
                                    requestCount
                            )
                        )
                    }

                switch result {
                case .complete:
                    accepted +=
                        requestCount

                case .partial(let count):
                    accepted +=
                        count.value
                    unavailable += 1

                case .unavailable:
                    unavailable += 1
                }

                if result == .unavailable {
                    break
                }
            }

            if destination.bufferedByteCount > 0 {
                if try destination.flush()
                    == .unavailable
                {
                    unavailable += 1
                }
            }

            for _ in 0..<4
            where consumed < logicalBytes
            {
                let availability =
                    try source.requestMore()

                if availability == .unavailable {
                    unavailable += 1
                }

                if source.bufferedByteCount > 0 {
                    let count =
                        min(
                            consumeSize,
                            min(
                                source.bufferedByteCount,
                                logicalBytes - consumed
                            )
                        )
                    try source.consume(
                        count
                    )
                    consumed +=
                        count
                }

                if availability == .end,
                   consumed < logicalBytes
                {
                    throw TestFailure(
                        message:
                            "\(label) reached end before requested bytes"
                    )
                }

                if availability == .unavailable,
                   source.bufferedByteCount == 0
                {
                    break
                }
            }

            if accepted == beforeAccepted,
               consumed == beforeConsumed,
               destination.bufferedByteCount
                == beforeBuffered
            {
                stagnant += 1
                if stagnant > 1_000_000 {
                    throw TestFailure(
                        message:
                            "\(label) stalled"
                    )
                }
            } else {
                stagnant = 0
            }
        }

        let elapsed =
            DispatchTime.now().uptimeNanoseconds
            - start

        guard source.refilledByteCount
                == UInt64(logicalBytes)
        else {
            throw TestFailure(
                message:
                    "\(label) refilled byte count mismatch"
            )
        }

        guard destination.drainedByteCount
                == UInt64(logicalBytes)
        else {
            throw TestFailure(
                message:
                    "\(label) drained byte count mismatch"
            )
        }

        return .init(
            nanoseconds: elapsed,
            transferredBytes: UInt64(consumed),
            boundaryCalls:
                source.refillCallCount
                + destination.drainCallCount,
            splitCalls:
                source.splitRefillCount
                + destination.splitDrainCount,
            unavailableCount:
                unavailable
        )
    }

    static func makeProductionRingSocketPair(
        _ descriptors: inout [Int32]
    ) -> Int32 {
        descriptors.withUnsafeMutableBufferPointer {
            buffer in

            #if canImport(Darwin)
            Darwin.socketpair(
                AF_UNIX,
                SOCK_STREAM,
                0,
                buffer.baseAddress
            )
            #elseif canImport(Glibc)
            Glibc.socketpair(
                AF_UNIX,
                Int32(
                    SOCK_STREAM.rawValue
                ),
                0,
                buffer.baseAddress
            )
            #endif
        }
    }

    static func collectProductionRingSamples(
        samples: Int,
        requireDeterministicBoundaryWork: Bool,
        expectedBytes: Int,
        production:
            () throws -> ProductionRingSample,
        generic:
            () throws -> ProductionRingSample
    ) throws -> (
        production: ProductionRingAggregate,
        generic: ProductionRingAggregate
    ) {
        var productionSamples:
            [ProductionRingSample] = []
        var genericSamples:
            [ProductionRingSample] = []

        for sample in 0..<samples {
            if sample.isMultiple(of: 2) {
                productionSamples.append(
                    try production()
                )
                genericSamples.append(
                    try generic()
                )
            } else {
                genericSamples.append(
                    try generic()
                )
                productionSamples.append(
                    try production()
                )
            }
        }

        for sample in productionSamples
            + genericSamples
        {
            guard sample.transferredBytes
                    == UInt64(expectedBytes)
            else {
                throw TestFailure(
                    message:
                        "production-ring lane transferred unequal logical bytes"
                )
            }
        }

        if requireDeterministicBoundaryWork {
            guard let reference =
                    productionSamples.first
            else {
                throw TestFailure(
                    message:
                        "production-ring benchmark has no production samples"
                )
            }

            for sample in productionSamples
                + genericSamples
            {
                guard sample.boundaryCalls
                        == reference.boundaryCalls,
                      sample.splitCalls
                        == reference.splitCalls,
                      sample.unavailableCount
                        == reference.unavailableCount
                else {
                    throw TestFailure(
                        message:
                            "production-ring deterministic lanes performed unequal boundary work"
                    )
                }
            }
        }

        return (
            aggregateProductionRingSamples(
                productionSamples
            ),
            aggregateProductionRingSamples(
                genericSamples
            )
        )
    }

    static func aggregateProductionRingSamples(
        _ samples: [ProductionRingSample]
    ) -> ProductionRingAggregate {
        let timings =
            samples
                .map(\.nanoseconds)
                .sorted()
        let median =
            timings[
                timings.count / 2
            ]
        let representative =
            samples.min {
                productionRingDistance(
                    $0.nanoseconds,
                    median
                )
                    < productionRingDistance(
                        $1.nanoseconds,
                        median
                    )
            }
            ?? samples[0]

        return .init(
            minimumNanoseconds:
                timings.first
                ?? median,
            medianNanoseconds:
                median,
            maximumNanoseconds:
                timings.last
                ?? median,
            boundaryCalls:
                representative.boundaryCalls,
            splitCalls:
                representative.splitCalls,
            unavailableCount:
                representative.unavailableCount
        )
    }

    static func printProductionRingRow(
        label: String,
        aggregates: (
            production: ProductionRingAggregate,
            generic: ProductionRingAggregate
        )
    ) {
        let timeRatio =
            Double(
                aggregates.generic
                    .medianNanoseconds
            )
            / Double(
                aggregates.production
                    .medianNanoseconds
            )
        let genericSpeedup =
            Double(
                aggregates.production
                    .medianNanoseconds
            )
            / Double(
                aggregates.generic
                    .medianNanoseconds
            )

        print(label)
        print(
            "  A production_erased "
            + formatProductionRingTiming(
                aggregates.production
            )
        )
        print(
            "  G generic_ring "
            + formatProductionRingTiming(
                aggregates.generic
            )
        )
        print(
            String(
                format:
                    "  G/A time %.3fx · generic speedup %.3fx",
                timeRatio,
                genericSpeedup
            )
        )
        print(
            "  calls A/G "
            + "\(aggregates.production.boundaryCalls)/\(aggregates.generic.boundaryCalls)"
            + " · split "
            + "\(aggregates.production.splitCalls)/\(aggregates.generic.splitCalls)"
            + " · unavailable "
            + "\(aggregates.production.unavailableCount)/\(aggregates.generic.unavailableCount)"
        )
        print("")
    }

    static func formatProductionRingTiming(
        _ aggregate: ProductionRingAggregate
    ) -> String {
        "\(formatProductionRingMilliseconds(aggregate.medianNanoseconds))"
            + " [\(formatProductionRingMilliseconds(aggregate.minimumNanoseconds))"
            + "…\(formatProductionRingMilliseconds(aggregate.maximumNanoseconds))]"
    }

    static func formatProductionRingMilliseconds(
        _ nanoseconds: UInt64
    ) -> String {
        String(
            format:
                "%.3f ms",
            Double(nanoseconds)
                / 1_000_000.0
        )
    }

    static func formatProductionRingBytes(
        _ bytes: Int
    ) -> String {
        if bytes >= 1024 * 1024 {
            return String(
                format:
                    "%.2f MiB",
                Double(bytes)
                    / Double(
                        1024 * 1024
                    )
            )
        }

        if bytes >= 1024 {
            return String(
                format:
                    "%.2f KiB",
                Double(bytes)
                    / 1024.0
            )
        }

        return "\(bytes) B"
    }

    static func productionRingDistance(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        lhs >= rhs
            ? lhs - rhs
            : rhs - lhs
    }
}
