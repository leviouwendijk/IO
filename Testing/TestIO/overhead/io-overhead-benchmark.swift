import Dispatch
import IO
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct IOOverheadMeasurement {
    let byteCount: UInt64
    let boundaryCallCount: UInt64
    let fragmentCount: UInt64?
}

private enum SharedLFStage: Int, CaseIterable, Hashable {
    case direct_posix
    case concrete_backend
    case existential_backend
    case stream_buffer
    case source

    var label: String {
        switch self {
        case .direct_posix:
            "read(2)+LF"
        case .concrete_backend:
            "concrete+LF"
        case .existential_backend:
            "existential+LF"
        case .stream_buffer:
            "StreamBuffer+LF"
        case .source:
            "Source+LF"
        }
    }
}

extension TestIO {
    static func runStandaloneIOOverheadBenchmarks(
        heavy: Bool
    ) throws {
        let fixtureLineCount = heavy
            ? 1_000_000
            : 300_000

        let fixture = try SelectionBenchmarkFixture.make(
            lineCount: fixtureLineCount
        )
        defer {
            try? FileManager.default.removeItem(
                at: fixture.url
            )
        }

        print("")
        print("standalone I/O overhead benchmark")
        print(
            "fixture: \(fixtureLineCount) lines · "
            + formatBytes(
                UInt64(
                    fixture.byteCount
                )
            )
        )
        print("")

        try runIOOverheadBenchmarks(
            fixture: fixture,
            iterations: heavy ? 3 : 5,
            heavy: heavy
        )
    }

    static func runIOOverheadBenchmarks(
        fixture: SelectionBenchmarkFixture,
        iterations: Int,
        heavy: Bool
    ) throws {
        let targetBytes = heavy
            ? 512 * 1024 * 1024
            : 256 * 1024 * 1024

        let passes = max(
            1,
            (targetBytes + fixture.byteCount - 1)
                / fixture.byteCount
        )

        let rounds = heavy
            ? max(15, iterations * 3)
            : max(9, iterations + 4)

        let logicalBytes = UInt64(
            fixture.byteCount * passes
        )

        print("I/O abstraction decomposition · identical LF-counting kernel")
        print("  read(2) → concrete SystemFileSource → existential → actual StreamBuffer → Source")
        print(
            "  each timed sample scans "
            + formatBytes(logicalBytes)
            + " via \(passes) warm-cache file pass"
            + (passes == 1 ? "" : "es")
            + "; \(rounds) interleaved rounds"
        )
        print("  stage order is deterministically shuffled each round to reduce cache/frequency bias")
        print("")

        for capacityValue in [4 * 1024, 64 * 1024] {
            let capacity = try BufferCapacity(
                capacityValue
            )

            let timings = try measureInterleavedSharedLFStages(
                fixture: fixture,
                capacity: capacity,
                passes: passes,
                rounds: rounds
            )

            let expectedLineFeeds = UInt64(
                fixture.lineCount * passes
            )

            for stage in SharedLFStage.allCases {
                guard let timing = timings[stage] else {
                    throw TestFailure(
                        message: "missing I/O overhead timing for \(stage.label)"
                    )
                }

                guard timing.value.byteCount == logicalBytes else {
                    throw TestFailure(
                        message:
                            "\(stage.label) byte-count mismatch: "
                            + "\(timing.value.byteCount) != \(logicalBytes)"
                    )
                }

                guard timing.value.fragmentCount == expectedLineFeeds else {
                    throw TestFailure(
                        message:
                            "\(stage.label) LF-count mismatch: "
                            + "\(timing.value.fragmentCount ?? 0) != \(expectedLineFeeds)"
                    )
                }
            }

            print(
                "  buffer "
                + formatBytes(
                    UInt64(capacityValue)
                )
            )

            var previous: Timed<IOOverheadMeasurement>?

            for stage in SharedLFStage.allCases {
                let timing = timings[stage]!
                printSharedKernelStageRow(
                    stage,
                    timing: timing,
                    baseline: timings[.direct_posix]!,
                    previous: previous
                )
                previous = timing
            }

            let scanner = try measure(
                iterations: max(
                    3,
                    min(
                        rounds,
                        iterations
                    )
                )
            ) {
                try ownershipScannerRead(
                    path: fixture.url.path,
                    capacity: capacity
                )
            }

            print("")
            print(
                "    semantic ByteLineScanner context"
            )
            print(
                "      scanner "
                + formatMilliseconds(
                    milliseconds(
                        scanner.medianNanoseconds
                    )
                )
                + " ms"
                + " · "
                + "\(scanner.value.boundaryCallCount) boundary calls"
                + " · "
                + "\(scanner.value.fragmentCount ?? 0) fragments"
                + " · single "
                + formatBytes(
                    UInt64(fixture.byteCount)
                )
                + " pass"
            )
            print("")
        }
    }

    private static func measureInterleavedSharedLFStages(
        fixture: SelectionBenchmarkFixture,
        capacity: BufferCapacity,
        passes: Int,
        rounds: Int
    ) throws -> [SharedLFStage: Timed<IOOverheadMeasurement>] {
        precondition(
            passes > 0
        )
        precondition(
            rounds > 0
        )

        // Warm every implementation before timed interleaving so page-cache population,
        // lazy symbol binding, and first-use allocator work are not assigned to one stage.
        for stage in SharedLFStage.allCases {
            _ = try runSharedLFStage(
                stage,
                path: fixture.url.path,
                capacity: capacity,
                passes: 1
            )
        }

        var durations: [SharedLFStage: [UInt64]] = [:]
        var values: [SharedLFStage: IOOverheadMeasurement] = [:]

        for round in 0..<rounds {
            for stage in interleavedStageOrder(
                round: round
            ) {
                let started =
                    DispatchTime.now()
                    .uptimeNanoseconds

                let value = try runSharedLFStage(
                    stage,
                    path: fixture.url.path,
                    capacity: capacity,
                    passes: passes
                )

                let ended =
                    DispatchTime.now()
                    .uptimeNanoseconds

                durations[
                    stage,
                    default: []
                ].append(
                    ended - started
                )
                values[stage] = value
            }
        }

        var result: [SharedLFStage: Timed<IOOverheadMeasurement>] = [:]

        for stage in SharedLFStage.allCases {
            guard var samples = durations[stage],
                  let value = values[stage]
            else {
                throw TestFailure(
                    message: "missing interleaved benchmark samples"
                )
            }

            samples.sort()

            result[stage] = .init(
                value: value,
                medianNanoseconds:
                    samples[
                        samples.count / 2
                    ],
                minimumNanoseconds:
                    samples[0],
                maximumNanoseconds:
                    samples[
                        samples.count - 1
                    ]
            )
        }

        return result
    }

    private static func interleavedStageOrder(
        round: Int
    ) -> [SharedLFStage] {
        var stages = SharedLFStage.allCases

        // Fixed-seed Fisher-Yates. The sequence is reproducible, but no stage is
        // systematically measured first or last across rounds.
        var state =
            UInt64(round)
            &+ 0x9E3779B97F4A7C15

        if stages.count > 1 {
            for index in stride(
                from: stages.count - 1,
                through: 1,
                by: -1
            ) {
                state =
                    state
                    &* 6364136223846793005
                    &+ 1442695040888963407

                let other = Int(
                    state
                    % UInt64(
                        index + 1
                    )
                )

                stages.swapAt(
                    index,
                    other
                )
            }
        }

        return stages
    }

    private static func runSharedLFStage(
        _ stage: SharedLFStage,
        path: String,
        capacity: BufferCapacity,
        passes: Int
    ) throws -> IOOverheadMeasurement {
        switch stage {
        case .direct_posix:
            try ownershipDirectPOSIXLineFeedScan(
                path: path,
                capacity: capacity,
                passes: passes
            )

        case .concrete_backend:
            try ownershipConcreteBackendLineFeedScan(
                path: path,
                capacity: capacity,
                passes: passes
            )

        case .existential_backend:
            try ownershipExistentialBackendLineFeedScan(
                path: path,
                capacity: capacity,
                passes: passes
            )

        case .stream_buffer:
            try ownershipStreamBufferLineFeedScan(
                path: path,
                capacity: capacity,
                passes: passes
            )

        case .source:
            try ownershipSourceLineFeedScan(
                path: path,
                capacity: capacity,
                passes: passes
            )
        }
    }

    private static func printSharedKernelStageRow(
        _ stage: SharedLFStage,
        timing: Timed<IOOverheadMeasurement>,
        baseline: Timed<IOOverheadMeasurement>,
        previous: Timed<IOOverheadMeasurement>?
    ) {
        let directRatio =
            Double(
                timing.medianNanoseconds
            )
            / Double(
                max(
                    1,
                    baseline.medianNanoseconds
                )
            )

        let priorRatio: String
        let boundaryDelta: String

        if let previous {
            let ratio =
                Double(
                    timing.medianNanoseconds
                )
                / Double(
                    max(
                        1,
                        previous.medianNanoseconds
                    )
                )

            priorRatio = String(
                format: "%.3fx",
                ratio
            )

            let delta =
                Int64(
                    timing.medianNanoseconds
                )
                - Int64(
                    previous.medianNanoseconds
                )

            let perBoundary =
                Double(delta)
                / Double(
                    max(
                        UInt64(1),
                        timing.value.boundaryCallCount
                    )
                )

            boundaryDelta = String(
                format: "%+.1f ns/boundary",
                perBoundary
            )
        } else {
            priorRatio = "baseline"
            boundaryDelta = "baseline"
        }

        print(
            "    "
            + stage.label.padding(
                toLength: 17,
                withPad: " ",
                startingAt: 0
            )
            + " "
            + formatMilliseconds(
                milliseconds(
                    timing.medianNanoseconds
                )
            )
            + " ms"
            + " ["
            + formatMilliseconds(
                milliseconds(
                    timing.minimumNanoseconds
                )
            )
            + "…"
            + formatMilliseconds(
                milliseconds(
                    timing.maximumNanoseconds
                )
            )
            + "]"
            + " · "
            + "\(timing.value.boundaryCallCount) boundaries"
            + " · vs prior \(priorRatio)"
            + " · vs read(2) "
            + String(
                format: "%.3fx",
                directRatio
            )
            + " · \(boundaryDelta)"
        )
    }

    private static func ownershipDirectPOSIXLineFeedScan(
        path: String,
        capacity: BufferCapacity,
        passes: Int
    ) throws -> IOOverheadMeasurement {
        var totalBytes: UInt64 = 0
        var totalCalls: UInt64 = 0
        var totalLineFeeds: UInt64 = 0

        for _ in 0..<passes {
            let descriptor = path.withCString {
                overheadOpenReadOnly(
                    $0
                )
            }

            guard descriptor >= 0 else {
                throw TestFailure(
                    message: "direct POSIX LF open failed"
                )
            }

            defer {
                _ = overheadClose(
                    descriptor
                )
            }

            var storage = Array(
                repeating: UInt8.zero,
                count: capacity.value
            )

            while true {
                let result = storage.withUnsafeMutableBytes {
                    overheadRead(
                        descriptor,
                        $0.baseAddress,
                        $0.count
                    )
                }
                totalCalls += 1

                if result > 0 {
                    totalBytes += UInt64(
                        result
                    )

                    totalLineFeeds += storage.withUnsafeBytes {
                        raw in
                        countLineFeeds(
                            UnsafeRawBufferPointer(
                                start: raw.baseAddress,
                                count: result
                            )
                        )
                    }
                    continue
                }

                if result == 0 {
                    break
                }

                if errno == EINTR {
                    continue
                }

                throw TestFailure(
                    message: "direct POSIX LF read failed"
                )
            }
        }

        return .init(
            byteCount: totalBytes,
            boundaryCallCount: totalCalls,
            fragmentCount: totalLineFeeds
        )
    }

    private static func ownershipConcreteBackendLineFeedScan(
        path: String,
        capacity: BufferCapacity,
        passes: Int
    ) throws -> IOOverheadMeasurement {
        var totalBytes: UInt64 = 0
        var totalCalls: UInt64 = 0
        var totalLineFeeds: UInt64 = 0

        for _ in 0..<passes {
            var backend = try SystemFileSource(
                path: path
            )
            var storage = Array(
                repeating: UInt8.zero,
                count: capacity.value
            )

            readLoop: while true {
                let refill = try storage.withUnsafeMutableBytes {
                    try backend.refill(
                        into: $0
                    )
                }
                totalCalls += 1

                switch refill {
                case .bytes(let count),
                     .final_bytes(let count):
                    totalBytes += UInt64(
                        count.value
                    )

                    totalLineFeeds += storage.withUnsafeBytes {
                        raw in
                        countLineFeeds(
                            UnsafeRawBufferPointer(
                                start: raw.baseAddress,
                                count: count.value
                            )
                        )
                    }

                    if case .final_bytes = refill {
                        break readLoop
                    }

                case .end:
                    break readLoop

                case .retry:
                    continue

                case .unavailable:
                    throw TestFailure(
                        message: "regular file concrete backend unavailable"
                    )
                }
            }
        }

        return .init(
            byteCount: totalBytes,
            boundaryCallCount: totalCalls,
            fragmentCount: totalLineFeeds
        )
    }

    private static func ownershipExistentialBackendLineFeedScan(
        path: String,
        capacity: BufferCapacity,
        passes: Int
    ) throws -> IOOverheadMeasurement {
        var totalBytes: UInt64 = 0
        var totalCalls: UInt64 = 0
        var totalLineFeeds: UInt64 = 0

        for _ in 0..<passes {
            var backend:
                any SourceBackend & ~Copyable =
                    try SystemFileSource(
                        path: path
                    )

            var storage = Array(
                repeating: UInt8.zero,
                count: capacity.value
            )

            readLoop: while true {
                let refill = try storage.withUnsafeMutableBytes {
                    try backend.refill(
                        into: $0
                    )
                }
                totalCalls += 1

                switch refill {
                case .bytes(let count),
                     .final_bytes(let count):
                    totalBytes += UInt64(
                        count.value
                    )

                    totalLineFeeds += storage.withUnsafeBytes {
                        raw in
                        countLineFeeds(
                            UnsafeRawBufferPointer(
                                start: raw.baseAddress,
                                count: count.value
                            )
                        )
                    }

                    if case .final_bytes = refill {
                        break readLoop
                    }

                case .end:
                    break readLoop

                case .retry:
                    continue

                case .unavailable:
                    throw TestFailure(
                        message: "regular file existential backend unavailable"
                    )
                }
            }
        }

        return .init(
            byteCount: totalBytes,
            boundaryCallCount: totalCalls,
            fragmentCount: totalLineFeeds
        )
    }

    private static func ownershipStreamBufferLineFeedScan(
        path: String,
        capacity: BufferCapacity,
        passes: Int
    ) throws -> IOOverheadMeasurement {
        var totalBytes: UInt64 = 0
        var totalCalls: UInt64 = 0
        var totalLineFeeds: UInt64 = 0

        for _ in 0..<passes {
            var backend:
                any SourceBackend & ~Copyable =
                    try SystemFileSource(
                        path: path
                    )

            var buffer = StreamBuffer(
                capacity: capacity
            )

            readLoop: while true {
                let writableCount =
                    buffer.writableCount

                precondition(
                    writableCount > 0
                )

                let refill = try buffer.withWritableBytes {
                    try backend.refill(
                        into: $0
                    )
                }
                totalCalls += 1

                switch refill {
                case .bytes(let count),
                     .final_bytes(let count):
                    guard count.value <= writableCount else {
                        throw TestFailure(
                            message: "StreamBuffer benchmark backend overreported"
                        )
                    }

                    buffer.didWrite(
                        count.value
                    )
                    totalBytes += UInt64(
                        count.value
                    )

                    totalLineFeeds += buffer.withReadableBytes {
                        countLineFeeds(
                            $0
                        )
                    }

                    buffer.consume(
                        buffer.readableCount
                    )

                    if case .final_bytes = refill {
                        break readLoop
                    }

                case .end:
                    break readLoop

                case .retry:
                    continue

                case .unavailable:
                    throw TestFailure(
                        message: "regular file StreamBuffer benchmark unavailable"
                    )
                }
            }
        }

        return .init(
            byteCount: totalBytes,
            boundaryCallCount: totalCalls,
            fragmentCount: totalLineFeeds
        )
    }

    private static func ownershipSourceLineFeedScan(
        path: String,
        capacity: BufferCapacity,
        passes: Int
    ) throws -> IOOverheadMeasurement {
        var totalBytes: UInt64 = 0
        var totalCalls: UInt64 = 0
        var totalLineFeeds: UInt64 = 0

        for _ in 0..<passes {
            var source = Source(
                try SystemFileSource(
                    path: path
                ),
                bufferCapacity: capacity
            )

            readLoop: while true {
                switch try source.prepare() {
                case .bytes:
                    let count =
                        source.bufferedByteCount

                    totalLineFeeds += source.withBytes {
                        countLineFeeds(
                            $0
                        )
                    }

                    try source.consume(
                        count
                    )

                case .end:
                    break readLoop

                case .unavailable:
                    throw TestFailure(
                        message: "regular file Source LF scan unavailable"
                    )

                case .buffer_full:
                    throw TestFailure(
                        message: "regular file Source LF scan unexpectedly full"
                    )
                }
            }

            let statistics =
                source.statistics

            totalBytes +=
                statistics.refilledByteCount
            totalCalls +=
                statistics.refillCallCount
        }

        return .init(
            byteCount: totalBytes,
            boundaryCallCount: totalCalls,
            fragmentCount: totalLineFeeds
        )
    }

    @inline(__always)
    private static func countLineFeeds(
        _ bytes: UnsafeRawBufferPointer
    ) -> UInt64 {
        var count: UInt64 = 0

        for byte in bytes where byte == 0x0A {
            count += 1
        }

        return count
    }

    private static func ownershipScannerRead(
        path: String,
        capacity: BufferCapacity
    ) throws -> IOOverheadMeasurement {
        var scanner = ByteLineScanner(
            source: Source(
                try SystemFileSource(
                    path: path
                ),
                bufferCapacity: capacity
            )
        )

        let result = try scanner.scan { _ in
            .continue
        }

        guard result == .end else {
            throw TestFailure(
                message: "regular file scanner did not reach EOF"
            )
        }

        let statistics =
            scanner.statistics

        return .init(
            byteCount:
                statistics.source.refilledByteCount,
            boundaryCallCount:
                statistics.source.refillCallCount,
            fragmentCount:
                statistics.fragmentCount
        )
    }
}

@inline(__always)
private func overheadOpenReadOnly(
    _ path: UnsafePointer<CChar>
) -> Int32 {
    #if canImport(Darwin)
    Darwin.open(path, O_RDONLY)
    #elseif canImport(Glibc)
    Glibc.open(path, O_RDONLY)
    #endif
}

@inline(__always)
private func overheadRead(
    _ descriptor: Int32,
    _ buffer: UnsafeMutableRawPointer?,
    _ count: Int
) -> Int {
    #if canImport(Darwin)
    Darwin.read(
        descriptor,
        buffer,
        count
    )
    #elseif canImport(Glibc)
    Glibc.read(
        descriptor,
        buffer,
        count
    )
    #endif
}

@inline(__always)
private func overheadClose(
    _ descriptor: Int32
) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(
        descriptor
    )
    #elseif canImport(Glibc)
    Glibc.close(
        descriptor
    )
    #endif
}
