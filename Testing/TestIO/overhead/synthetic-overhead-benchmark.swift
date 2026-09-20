import Dispatch
import IO
import Foundation

/// Stages in the synthetic in-memory decomposition benchmark.
///
/// Every stage copies from the same small repeating payload into caller-owned writable
/// storage and executes the same LF-counting kernel. The only intended difference between
/// stages is the abstraction machinery crossed on the way to those bytes.
private enum SyntheticIOStage: Int, CaseIterable, Hashable {
    case direct_cursor
    case concrete_backend
    case existential_backend
    case stream_buffer
    case source

    var label: String {
        switch self {
        case .direct_cursor:
            "direct memory"
        case .concrete_backend:
            "concrete backend"
        case .existential_backend:
            "existential backend"
        case .stream_buffer:
            "StreamBuffer"
        case .source:
            "Source"
        }
    }
}

private struct SyntheticIOResult: Equatable {
    let byteCount: UInt64
    let boundaryCallCount: UInt64
    let lineFeedCount: UInt64
}

private struct SyntheticIOTiming {
    let value: SyntheticIOResult
    let medianNanoseconds: UInt64
    let minimumNanoseconds: UInt64
    let maximumNanoseconds: UInt64
}

/// Copyable cursor used as the ground-truth producer for the synthetic benchmark.
///
/// The backing payload is intentionally tiny and repeated cyclically. `totalByteCount`
/// describes logical work, not resident or on-disk storage. This lets the benchmark
/// process hundreds of MiB or more while owning only a small in-memory pattern.
private struct SyntheticPatternCursor {
    let pattern: [UInt8]
    let totalByteCount: Int

    private(set) var producedByteCount: Int
    private var patternOffset: Int

    init(
        pattern: [UInt8],
        totalByteCount: Int
    ) {
        self.pattern = pattern
        self.totalByteCount = totalByteCount
        self.producedByteCount = 0
        self.patternOffset = 0
    }

    var isExhausted: Bool {
        producedByteCount == totalByteCount
    }

    mutating func fill(
        into output: UnsafeMutableRawBufferPointer,
        maximumChunkSize: Int
    ) -> Int {
        guard !isExhausted,
              !output.isEmpty,
              maximumChunkSize > 0
        else {
            return 0
        }

        precondition(!pattern.isEmpty)

        let count = min(
            output.count,
            min(
                maximumChunkSize,
                totalByteCount - producedByteCount
            )
        )

        guard count > 0 else {
            return 0
        }

        guard let destinationBase = output.baseAddress else {
            preconditionFailure(
                "A non-empty synthetic output span must have a base address."
            )
        }

        var written = 0

        pattern.withUnsafeBytes { patternBytes in
            guard let patternBase = patternBytes.baseAddress else {
                preconditionFailure(
                    "A non-empty synthetic pattern must have a base address."
                )
            }

            while written < count {
                let availableBeforeWrap = pattern.count - patternOffset
                let copyCount = min(
                    availableBeforeWrap,
                    count - written
                )

                destinationBase
                    .advanced(by: written)
                    .copyMemory(
                        from: patternBase.advanced(by: patternOffset),
                        byteCount: copyCount
                    )

                written += copyCount
                patternOffset += copyCount

                if patternOffset == pattern.count {
                    patternOffset = 0
                }
            }
        }

        producedByteCount += count
        return count
    }
}

/// Noncopyable SourceBackend realization over the same synthetic cursor used by the
/// direct baseline.
private struct SyntheticSourceBackend: SourceBackend, ~Copyable {
    private var cursor: SyntheticPatternCursor
    private let maximumChunkSize: Int

    init(
        pattern: [UInt8],
        totalByteCount: Int,
        maximumChunkSize: Int
    ) {
        self.cursor = .init(
            pattern: pattern,
            totalByteCount: totalByteCount
        )
        self.maximumChunkSize = maximumChunkSize
    }

    mutating func refill(
        into output: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        let count = cursor.fill(
            into: output,
            maximumChunkSize: maximumChunkSize
        )

        guard count > 0 else {
            return .end
        }

        let progress = try PositiveByteCount(
            count
        )

        if cursor.isExhausted {
            return .final_bytes(
                progress
            )
        }

        return .bytes(
            progress
        )
    }
}

extension TestIO {
    /// Small regular-suite proof that the synthetic harness itself preserves bytes,
    /// boundaries, and LF counts across every abstraction stage.
    static func testSyntheticOverheadHarnessEquivalence() throws {
        let pattern = syntheticBenchmarkPattern(
            byteCount: 257
        )
        let totalByteCount = 4_097

        for chunkSize in [1, 7, 64, 257] {
            let capacity = try BufferCapacity(
                max(1, chunkSize)
            )

            let baseline = try runSyntheticIOStage(
                .direct_cursor,
                pattern: pattern,
                totalByteCount: totalByteCount,
                maximumChunkSize: chunkSize,
                capacity: capacity
            )

            for stage in SyntheticIOStage.allCases.dropFirst() {
                let result = try runSyntheticIOStage(
                    stage,
                    pattern: pattern,
                    totalByteCount: totalByteCount,
                    maximumChunkSize: chunkSize,
                    capacity: capacity
                )

                try expectEqual(
                    result,
                    baseline,
                    "synthetic harness \(stage.label) chunk \(chunkSize)"
                )
            }
        }
    }

    /// Runs only synthetic in-memory overhead measurements.
    ///
    /// Disk footprint is effectively zero: the benchmark holds one small reusable pattern
    /// in memory and never writes a large benchmark fixture. Logical throughput is created
    /// by repeatedly cycling that pattern through the same producer/consumer kernels.
    static func runSyntheticIOOverheadBenchmarks(
        heavy: Bool
    ) throws {
        let patternByteCount = 64 * 1024
        let pattern = syntheticBenchmarkPattern(
            byteCount: patternByteCount
        )

        print("")
        print("synthetic in-memory I/O overhead benchmark")
        print(
            "backing pattern: "
            + formatBytes(UInt64(patternByteCount))
            + " RAM · no benchmark file is written"
        )
        print("every stage uses the same memory-copy producer and LF-counting kernel")
        print("")

        let throughputBytes = heavy
            ? 512 * 1024 * 1024
            : 256 * 1024 * 1024
        let throughputRounds = heavy
            ? 15
            : 9

        try runSyntheticIORegime(
            name: "realistic throughput",
            pattern: pattern,
            totalByteCount: throughputBytes,
            maximumChunkSize: 64 * 1024,
            capacity: try BufferCapacity(64 * 1024),
            rounds: throughputRounds
        )

        // Millions of one-byte transitions deliberately magnify witness dispatch, enum
        // handling, cursor bookkeeping, statistics updates, prepare/requestMore/apply, and
        // StreamBuffer state transitions. The logical byte budget is intentionally small
        // so this stress case remains practical.
        let stressBytes = heavy
            ? 2 * 1024 * 1024
            : 1 * 1024 * 1024
        let stressRounds = heavy
            ? 7
            : 5

        try runSyntheticIORegime(
            name: "one-byte boundary stress",
            pattern: pattern,
            totalByteCount: stressBytes,
            maximumChunkSize: 1,
            capacity: try BufferCapacity(1),
            rounds: stressRounds
        )

        try runOptimizedSourceSILProbe()
    }

    private static func runSyntheticIORegime(
        name: String,
        pattern: [UInt8],
        totalByteCount: Int,
        maximumChunkSize: Int,
        capacity: BufferCapacity,
        rounds: Int
    ) throws {
        let timings = try measureInterleavedSyntheticStages(
            pattern: pattern,
            totalByteCount: totalByteCount,
            maximumChunkSize: maximumChunkSize,
            capacity: capacity,
            rounds: rounds
        )

        guard let baseline = timings[.direct_cursor] else {
            throw TestFailure(
                message: "missing synthetic direct baseline"
            )
        }

        let expectedBytes = UInt64(
            totalByteCount
        )
        let expectedBoundaries = UInt64(
            (totalByteCount + maximumChunkSize - 1)
                / maximumChunkSize
        )

        print(name)
        print(
            "  logical work: "
            + formatBytes(expectedBytes)
            + " · progress cap "
            + formatBytes(UInt64(maximumChunkSize))
            + " · \(expectedBoundaries) boundaries/sample · \(rounds) interleaved rounds"
        )

        var previous: SyntheticIOTiming?

        for stage in SyntheticIOStage.allCases {
            guard let timing = timings[stage] else {
                throw TestFailure(
                    message: "missing synthetic timing for \(stage.label)"
                )
            }

            guard timing.value.byteCount == expectedBytes else {
                throw TestFailure(
                    message: "synthetic \(stage.label) byte-count mismatch"
                )
            }

            guard timing.value.boundaryCallCount == expectedBoundaries else {
                throw TestFailure(
                    message:
                        "synthetic \(stage.label) boundary-count mismatch: "
                        + "\(timing.value.boundaryCallCount) != \(expectedBoundaries)"
                )
            }

            guard timing.value.lineFeedCount == baseline.value.lineFeedCount else {
                throw TestFailure(
                    message: "synthetic \(stage.label) LF-count mismatch"
                )
            }

            printSyntheticTimingRow(
                stage: stage,
                timing: timing,
                baseline: baseline,
                previous: previous
            )

            previous = timing
        }

        print("")
    }

    private static func measureInterleavedSyntheticStages(
        pattern: [UInt8],
        totalByteCount: Int,
        maximumChunkSize: Int,
        capacity: BufferCapacity,
        rounds: Int
    ) throws -> [SyntheticIOStage: SyntheticIOTiming] {
        precondition(totalByteCount > 0)
        precondition(maximumChunkSize > 0)
        precondition(rounds > 0)

        // Warm every stage once before timed rounds.
        for stage in SyntheticIOStage.allCases {
            _ = try runSyntheticIOStage(
                stage,
                pattern: pattern,
                totalByteCount: min(
                    totalByteCount,
                    max(
                        maximumChunkSize,
                        64 * 1024
                    )
                ),
                maximumChunkSize: maximumChunkSize,
                capacity: capacity
            )
        }

        var durations: [SyntheticIOStage: [UInt64]] = [:]
        var values: [SyntheticIOStage: SyntheticIOResult] = [:]

        for round in 0..<rounds {
            for stage in syntheticInterleavedStageOrder(
                round: round
            ) {
                let started = DispatchTime.now().uptimeNanoseconds

                let value = try runSyntheticIOStage(
                    stage,
                    pattern: pattern,
                    totalByteCount: totalByteCount,
                    maximumChunkSize: maximumChunkSize,
                    capacity: capacity
                )

                let ended = DispatchTime.now().uptimeNanoseconds

                durations[stage, default: []].append(
                    ended - started
                )
                values[stage] = value
            }
        }

        var result: [SyntheticIOStage: SyntheticIOTiming] = [:]

        for stage in SyntheticIOStage.allCases {
            guard var samples = durations[stage],
                  let value = values[stage]
            else {
                throw TestFailure(
                    message: "missing synthetic benchmark samples"
                )
            }

            samples.sort()

            result[stage] = .init(
                value: value,
                medianNanoseconds: samples[samples.count / 2],
                minimumNanoseconds: samples[0],
                maximumNanoseconds: samples[samples.count - 1]
            )
        }

        return result
    }

    private static func syntheticInterleavedStageOrder(
        round: Int
    ) -> [SyntheticIOStage] {
        var stages = SyntheticIOStage.allCases
        var state = UInt64(round) &+ 0xD1B54A32D192ED03

        if stages.count > 1 {
            for index in stride(
                from: stages.count - 1,
                through: 1,
                by: -1
            ) {
                state = state
                    &* 2862933555777941757
                    &+ 3037000493

                let other = Int(
                    state % UInt64(index + 1)
                )
                stages.swapAt(index, other)
            }
        }

        return stages
    }

    private static func runSyntheticIOStage(
        _ stage: SyntheticIOStage,
        pattern: [UInt8],
        totalByteCount: Int,
        maximumChunkSize: Int,
        capacity: BufferCapacity
    ) throws -> SyntheticIOResult {
        switch stage {
        case .direct_cursor:
            return syntheticDirectCursorScan(
                pattern: pattern,
                totalByteCount: totalByteCount,
                maximumChunkSize: maximumChunkSize,
                capacity: capacity
            )

        case .concrete_backend:
            return try syntheticConcreteBackendScan(
                pattern: pattern,
                totalByteCount: totalByteCount,
                maximumChunkSize: maximumChunkSize,
                capacity: capacity
            )

        case .existential_backend:
            return try syntheticExistentialBackendScan(
                pattern: pattern,
                totalByteCount: totalByteCount,
                maximumChunkSize: maximumChunkSize,
                capacity: capacity
            )

        case .stream_buffer:
            return try syntheticStreamBufferScan(
                pattern: pattern,
                totalByteCount: totalByteCount,
                maximumChunkSize: maximumChunkSize,
                capacity: capacity
            )

        case .source:
            return try syntheticSourceScan(
                pattern: pattern,
                totalByteCount: totalByteCount,
                maximumChunkSize: maximumChunkSize,
                capacity: capacity
            )
        }
    }

    private static func syntheticDirectCursorScan(
        pattern: [UInt8],
        totalByteCount: Int,
        maximumChunkSize: Int,
        capacity: BufferCapacity
    ) -> SyntheticIOResult {
        var cursor = SyntheticPatternCursor(
            pattern: pattern,
            totalByteCount: totalByteCount
        )
        var storage = Array(
            repeating: UInt8.zero,
            count: capacity.value
        )

        var bytes: UInt64 = 0
        var calls: UInt64 = 0
        var lineFeeds: UInt64 = 0

        while !cursor.isExhausted {
            let count = storage.withUnsafeMutableBytes {
                cursor.fill(
                    into: $0,
                    maximumChunkSize: maximumChunkSize
                )
            }
            precondition(count > 0)
            calls += 1
            bytes += UInt64(count)

            lineFeeds += storage.withUnsafeBytes { raw in
                syntheticCountLineFeeds(
                    UnsafeRawBufferPointer(
                        start: raw.baseAddress,
                        count: count
                    )
                )
            }
        }

        return .init(
            byteCount: bytes,
            boundaryCallCount: calls,
            lineFeedCount: lineFeeds
        )
    }

    private static func syntheticConcreteBackendScan(
        pattern: [UInt8],
        totalByteCount: Int,
        maximumChunkSize: Int,
        capacity: BufferCapacity
    ) throws -> SyntheticIOResult {
        var backend = SyntheticSourceBackend(
            pattern: pattern,
            totalByteCount: totalByteCount,
            maximumChunkSize: maximumChunkSize
        )
        var storage = Array(
            repeating: UInt8.zero,
            count: capacity.value
        )

        return try consumeSyntheticBackend(
            backend: &backend,
            storage: &storage
        )
    }

    private static func syntheticExistentialBackendScan(
        pattern: [UInt8],
        totalByteCount: Int,
        maximumChunkSize: Int,
        capacity: BufferCapacity
    ) throws -> SyntheticIOResult {
        var backend: any SourceBackend & ~Copyable =
            SyntheticSourceBackend(
                pattern: pattern,
                totalByteCount: totalByteCount,
                maximumChunkSize: maximumChunkSize
            )
        var storage = Array(
            repeating: UInt8.zero,
            count: capacity.value
        )

        var bytes: UInt64 = 0
        var calls: UInt64 = 0
        var lineFeeds: UInt64 = 0

        scanLoop: while true {
            let refill = try storage.withUnsafeMutableBytes {
                try backend.refill(
                    into: $0
                )
            }
            calls += 1

            switch refill {
            case .bytes(let count),
                 .final_bytes(let count):
                bytes += UInt64(count.value)
                lineFeeds += storage.withUnsafeBytes { raw in
                    syntheticCountLineFeeds(
                        UnsafeRawBufferPointer(
                            start: raw.baseAddress,
                            count: count.value
                        )
                    )
                }

                if case .final_bytes = refill {
                    break scanLoop
                }

            case .end:
                break scanLoop

            case .retry:
                continue

            case .unavailable:
                throw TestFailure(
                    message: "synthetic existential backend unavailable"
                )
            }
        }

        return .init(
            byteCount: bytes,
            boundaryCallCount: calls,
            lineFeedCount: lineFeeds
        )
    }

    private static func consumeSyntheticBackend<Backend: SourceBackend & ~Copyable>(
        backend: inout Backend,
        storage: inout [UInt8]
    ) throws -> SyntheticIOResult {
        var bytes: UInt64 = 0
        var calls: UInt64 = 0
        var lineFeeds: UInt64 = 0

        scanLoop: while true {
            let refill = try storage.withUnsafeMutableBytes {
                try backend.refill(
                    into: $0
                )
            }
            calls += 1

            switch refill {
            case .bytes(let count),
                 .final_bytes(let count):
                bytes += UInt64(count.value)
                lineFeeds += storage.withUnsafeBytes { raw in
                    syntheticCountLineFeeds(
                        UnsafeRawBufferPointer(
                            start: raw.baseAddress,
                            count: count.value
                        )
                    )
                }

                if case .final_bytes = refill {
                    break scanLoop
                }

            case .end:
                break scanLoop

            case .retry:
                continue

            case .unavailable:
                throw TestFailure(
                    message: "synthetic concrete backend unavailable"
                )
            }
        }

        return .init(
            byteCount: bytes,
            boundaryCallCount: calls,
            lineFeedCount: lineFeeds
        )
    }

    private static func syntheticStreamBufferScan(
        pattern: [UInt8],
        totalByteCount: Int,
        maximumChunkSize: Int,
        capacity: BufferCapacity
    ) throws -> SyntheticIOResult {
        var backend: any SourceBackend & ~Copyable =
            SyntheticSourceBackend(
                pattern: pattern,
                totalByteCount: totalByteCount,
                maximumChunkSize: maximumChunkSize
            )
        var buffer = StreamBuffer(
            capacity: capacity
        )

        var bytes: UInt64 = 0
        var calls: UInt64 = 0
        var lineFeeds: UInt64 = 0

        scanLoop: while true {
            let writableCount = buffer.writableCount
            precondition(writableCount > 0)

            let refill = try buffer.withWritableBytes {
                try backend.refill(
                    into: $0
                )
            }
            calls += 1

            switch refill {
            case .bytes(let count),
                 .final_bytes(let count):
                guard count.value <= writableCount else {
                    throw TestFailure(
                        message: "synthetic StreamBuffer backend overreported"
                    )
                }

                buffer.didWrite(
                    count.value
                )
                bytes += UInt64(
                    count.value
                )
                lineFeeds += buffer.withReadableBytes {
                    syntheticCountLineFeeds(
                        $0
                    )
                }
                buffer.consume(
                    buffer.readableCount
                )

                if case .final_bytes = refill {
                    break scanLoop
                }

            case .end:
                break scanLoop

            case .retry:
                continue

            case .unavailable:
                throw TestFailure(
                    message: "synthetic StreamBuffer backend unavailable"
                )
            }
        }

        return .init(
            byteCount: bytes,
            boundaryCallCount: calls,
            lineFeedCount: lineFeeds
        )
    }

    private static func syntheticSourceScan(
        pattern: [UInt8],
        totalByteCount: Int,
        maximumChunkSize: Int,
        capacity: BufferCapacity
    ) throws -> SyntheticIOResult {
        var source = Source(
            SyntheticSourceBackend(
                pattern: pattern,
                totalByteCount: totalByteCount,
                maximumChunkSize: maximumChunkSize
            ),
            bufferCapacity: capacity
        )

        var bytes: UInt64 = 0
        var lineFeeds: UInt64 = 0

        scanLoop: while true {
            switch try source.prepare() {
            case .bytes:
                let count = source.bufferedByteCount
                lineFeeds += source.withBytes {
                    syntheticCountLineFeeds(
                        $0
                    )
                }
                try source.consume(
                    count
                )
                bytes += UInt64(
                    count
                )

            case .end:
                break scanLoop

            case .unavailable:
                throw TestFailure(
                    message: "synthetic Source unavailable"
                )

            case .buffer_full:
                throw TestFailure(
                    message: "synthetic Source unexpectedly buffer-full"
                )
            }
        }

        let statistics = source.statistics

        return .init(
            byteCount: bytes,
            boundaryCallCount: statistics.refillCallCount,
            lineFeedCount: lineFeeds
        )
    }

    private static func printSyntheticTimingRow(
        stage: SyntheticIOStage,
        timing: SyntheticIOTiming,
        baseline: SyntheticIOTiming,
        previous: SyntheticIOTiming?
    ) {
        let baselineRatio =
            Double(timing.medianNanoseconds)
            / Double(max(1, baseline.medianNanoseconds))

        let priorRatio: String
        let boundaryDelta: String

        if let previous {
            let ratio =
                Double(timing.medianNanoseconds)
                / Double(max(1, previous.medianNanoseconds))

            priorRatio = String(
                format: "%.3fx",
                ratio
            )

            let delta =
                Int64(timing.medianNanoseconds)
                - Int64(previous.medianNanoseconds)
            let perBoundary =
                Double(delta)
                / Double(max(UInt64(1), timing.value.boundaryCallCount))

            boundaryDelta = String(
                format: "%+.1f ns/boundary",
                perBoundary
            )
        } else {
            priorRatio = "baseline"
            boundaryDelta = "baseline"
        }

        print(
            "  "
            + stage.label.padding(
                toLength: 20,
                withPad: " ",
                startingAt: 0
            )
            + String(
                format: "%8.3f ms",
                Double(timing.medianNanoseconds) / 1_000_000.0
            )
            + " ["
            + String(
                format: "%.3f",
                Double(timing.minimumNanoseconds) / 1_000_000.0
            )
            + "…"
            + String(
                format: "%.3f",
                Double(timing.maximumNanoseconds) / 1_000_000.0
            )
            + "] · vs prior "
            + priorRatio
            + " · vs direct "
            + String(
                format: "%.3fx",
                baselineRatio
            )
            + " · "
            + boundaryDelta
        )
    }

    @inline(__always)
    private static func syntheticCountLineFeeds(
        _ bytes: UnsafeRawBufferPointer
    ) -> UInt64 {
        var count: UInt64 = 0

        for byte in bytes where byte == 0x0A {
            count += 1
        }

        return count
    }

    private static func syntheticBenchmarkPattern(
        byteCount: Int
    ) -> [UInt8] {
        precondition(byteCount > 0)

        var bytes = Array(
            repeating: UInt8(ascii: "a"),
            count: byteCount
        )

        for index in bytes.indices {
            bytes[index] = UInt8(
                97 + (index % 26)
            )

            // Deliberately irregular enough that line feeds do not align neatly with common
            // powers-of-two chunk sizes.
            if index % 97 == 96 {
                bytes[index] = 0x0A
            }
        }

        return bytes
    }

    /// Emits a small optimized client SIL probe entirely through pipes.
    ///
    /// The probe is intentionally observational: it reports which public Source calls remain
    /// visible in optimized client SIL. It does not write `.sil` or assembly files and does
    /// not mutate IO based on the result.
    private static func runOptimizedSourceSILProbe() throws {
        let moduleSearchPath = try syntheticIOModuleSearchPath()

        let source = """
        import IO

        public func optimizedClientProbe(
            _ input: consuming Source
        ) throws -> UInt64 {
            var source = consume input
            var lineFeeds: UInt64 = 0

            while true {
                switch try source.prepare() {
                case .bytes:
                    let count = source.bufferedByteCount
                    lineFeeds += source.withBytes { bytes in
                        var local: UInt64 = 0
                        for byte in bytes where byte == 0x0A {
                            local += 1
                        }
                        return local
                    }
                    try source.consume(count)

                case .end:
                    return lineFeeds

                case .unavailable, .buffer_full:
                    return lineFeeds
                }
            }
        }
        """

        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/usr/bin/env"
        )
        process.arguments = [
            "swiftc",
            "-O",
            "-emit-sil",
            "-I",
            moduleSearchPath.path,
            "-",
        ]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        try process.run()

        input.fileHandleForWriting.write(
            Data(source.utf8)
        )
        try input.fileHandleForWriting.close()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw TestFailure(
                message:
                    "optimized Source SIL probe failed:\n"
                    + String(decoding: data, as: UTF8.self)
            )
        }

        let sil = String(
            decoding: data,
            as: UTF8.self
        )

        let prepareRefs = syntheticOccurrenceCount(
            "function_ref Source.prepare()",
            in: sil
        )
        let requestMoreRefs = syntheticOccurrenceCount(
            "function_ref Source.requestMore()",
            in: sil
        )
        let withBytesRefs = syntheticOccurrenceCount(
            "function_ref Source.withBytes",
            in: sil
        )
        let consumeRefs = syntheticOccurrenceCount(
            "function_ref Source.consume(_:)",
            in: sil
        )
        let witnessMethods = syntheticOccurrenceCount(
            "witness_method",
            in: sil
        )

        print("optimized client SIL probe")
        print(
            "  captured in memory: "
            + formatBytes(UInt64(data.count))
            + " · no SIL/assembly file written"
        )
        print("  Source.prepare function refs: \(prepareRefs)")
        print("  Source.requestMore function refs: \(requestMoreRefs)")
        print("  Source.withBytes function refs: \(withBytesRefs)")
        print("  Source.consume function refs: \(consumeRefs)")
        print("  witness_method instructions visible in client SIL: \(witnessMethods)")
        print(
            "  note: zero or nonzero counts are observations of this compiler/build, not API requirements"
        )
        print("")
    }

    private static func syntheticIOModuleSearchPath() throws -> URL {
        let executable = URL(
            fileURLWithPath: CommandLine.arguments[0]
        ).standardizedFileURL

        let modules = executable
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Modules",
                isDirectory: true
            )

        guard FileManager.default.fileExists(
            atPath: modules.path
        ) else {
            throw TestFailure(
                message:
                    "could not locate sibling SwiftPM Modules directory at "
                    + modules.path
            )
        }

        return modules
    }

    private static func syntheticOccurrenceCount(
        _ needle: String,
        in haystack: String
    ) -> Int {
        guard !needle.isEmpty else {
            return 0
        }

        var count = 0
        var searchStart = haystack.startIndex

        while let range = haystack.range(
            of: needle,
            range: searchStart..<haystack.endIndex
        ) {
            count += 1
            searchStart = range.upperBound
        }

        return count
    }
}
