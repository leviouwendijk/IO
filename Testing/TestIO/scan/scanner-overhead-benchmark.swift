import Dispatch
import IO
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private enum ScannerProbeProfile: CaseIterable {
    case short_lines
    case medium_lines
    case sparse_lines

    var label: String {
        switch self {
        case .short_lines:
            "short lines (~32 B)"
        case .medium_lines:
            "medium lines (~4 KiB)"
        case .sparse_lines:
            "sparse LF (~64 KiB)"
        }
    }

    var lineStride: Int {
        switch self {
        case .short_lines:
            31
        case .medium_lines:
            4093
        case .sparse_lines:
            65_521
        }
    }
}

private enum ScannerProbeStage: Int, CaseIterable, Hashable {
    case byte_search
    case memchr_search
    case state_only
    case metadata_only
    case callback_no_stats
    case callback_stats
    case memchr_callback_stats
    case current_noop
    case current_callback

    var label: String {
        switch self {
        case .byte_search:
            "byte search"
        case .memchr_search:
            "memchr search"
        case .state_only:
            "state only"
        case .metadata_only:
            "metadata only"
        case .callback_no_stats:
            "callback/no stats"
        case .callback_stats:
            "callback + stats"
        case .memchr_callback_stats:
            "memchr callback"
        case .current_noop:
            "current/no-op"
        case .current_callback:
            "current/callback"
        }
    }
}

private struct ScannerProbeResult: Equatable {
    let byteCount: UInt64
    let lineFeedCount: UInt64
    let fragmentCount: UInt64
    let checksum: UInt64
}

private struct ScannerProbeTiming {
    let value: ScannerProbeResult
    let medianNanoseconds: UInt64
    let minimumNanoseconds: UInt64
    let maximumNanoseconds: UInt64
}

private struct ScannerProbeFragment {
    let lineNumber: UInt64
    let lineStartOffset: UInt64
    let byteRange: Range<UInt64>
    let byteCount: Int
    let ending: ByteLineFragmentEnding
}

private struct ScannerProbeCursor {
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

        let count = min(
            output.count,
            min(
                maximumChunkSize,
                totalByteCount - producedByteCount
            )
        )

        guard count > 0,
              let destinationBase = output.baseAddress
        else {
            return 0
        }

        var written = 0

        pattern.withUnsafeBytes { patternBytes in
            guard let patternBase = patternBytes.baseAddress else {
                preconditionFailure("scanner probe pattern unexpectedly empty")
            }

            while written < count {
                let beforeWrap = pattern.count - patternOffset
                let copyCount = min(
                    beforeWrap,
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

private struct ScannerProbeBackend: SourceBackend, ~Copyable {
    private var cursor: ScannerProbeCursor
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
    static func testScannerProbeEquivalence() throws {
        let pattern = scannerProbePattern(
            profile: .short_lines,
            byteCount: 64 * 1024
        )
        let totalByteCount = pattern.count * 3
        let capacity = try BufferCapacity(
            4096
        )

        let reference = try scannerProbeRun(
            stage: .callback_stats,
            pattern: pattern,
            totalByteCount: totalByteCount,
            capacity: capacity
        )
        let memchr = try scannerProbeRun(
            stage: .memchr_callback_stats,
            pattern: pattern,
            totalByteCount: totalByteCount,
            capacity: capacity
        )
        let current = try scannerProbeRun(
            stage: .current_callback,
            pattern: pattern,
            totalByteCount: totalByteCount,
            capacity: capacity
        )

        try expectEqual(
            memchr,
            reference,
            "memchr scanner probe equivalence"
        )
        try expectEqual(
            current,
            reference,
            "current scanner probe equivalence"
        )
    }

    static func runScannerOverheadBenchmarks(
        heavy: Bool
    ) throws {
        let patternByteCount = 64 * 1024
        let totalByteCount = heavy
            ? 64 * 1024 * 1024
            : 32 * 1024 * 1024
        let rounds = heavy ? 9 : 5
        let capacity = try BufferCapacity(
            64 * 1024
        )

        print("ByteLineScanner decomposition · in-memory")
        print(
            "  backing pattern: "
            + formatBytes(UInt64(patternByteCount))
            + " RAM · no benchmark file"
        )
        print(
            "  logical work/sample: "
            + formatBytes(UInt64(totalByteCount))
            + " · Source buffer "
            + formatBytes(UInt64(capacity.value))
            + " · \(rounds) interleaved rounds"
        )
        print(
            "  local stages are diagnostic clones; current/* rows are the production ByteLineScanner"
        )
        print("")

        for (profileIndex, profile) in ScannerProbeProfile.allCases.enumerated() {
            let pattern = scannerProbePattern(
                profile: profile,
                byteCount: patternByteCount
            )

            var samples: [ScannerProbeStage: [UInt64]] = [:]
            var values: [ScannerProbeStage: ScannerProbeResult] = [:]

            // Warm every path once before timed rounds.
            for stage in ScannerProbeStage.allCases {
                let value = try scannerProbeRun(
                    stage: stage,
                    pattern: pattern,
                    totalByteCount: totalByteCount,
                    capacity: capacity
                )
                values[stage] = value
            }

            try scannerProbeCheckSemanticEquivalence(
                values: values,
                profile: profile
            )

            for round in 0..<rounds {
                let order = scannerProbeInterleavedOrder(
                    round: round,
                    profileIndex: profileIndex
                )

                for stage in order {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let value = try scannerProbeRun(
                        stage: stage,
                        pattern: pattern,
                        totalByteCount: totalByteCount,
                        capacity: capacity
                    )
                    let end = DispatchTime.now().uptimeNanoseconds

                    if let expected = values[stage] {
                        guard value == expected else {
                            throw TestFailure(
                                message: "scanner probe result changed between rounds for \(stage.label)"
                            )
                        }
                    } else {
                        values[stage] = value
                    }

                    samples[stage, default: []].append(
                        end - start
                    )
                }
            }

            var timings: [ScannerProbeStage: ScannerProbeTiming] = [:]

            for stage in ScannerProbeStage.allCases {
                guard let stageSamples = samples[stage],
                      let value = values[stage]
                else {
                    throw TestFailure(
                        message: "missing scanner probe timing for \(stage.label)"
                    )
                }

                let sorted = stageSamples.sorted()
                timings[stage] = .init(
                    value: value,
                    medianNanoseconds: sorted[sorted.count / 2],
                    minimumNanoseconds: sorted[0],
                    maximumNanoseconds: sorted[sorted.count - 1]
                )
            }

            guard let baseline = timings[.byte_search] else {
                throw TestFailure(
                    message: "missing byte-search scanner baseline"
                )
            }

            print(profile.label)
            print(
                "  expected LF: "
                + String(baseline.value.lineFeedCount)
                + " · production fragments: "
                + String(
                    timings[.current_callback]?.value.fragmentCount ?? 0
                )
            )

            var previous: ScannerProbeTiming?

            for stage in ScannerProbeStage.allCases {
                guard let timing = timings[stage] else {
                    continue
                }

                scannerProbePrintTiming(
                    stage: stage,
                    timing: timing,
                    baseline: baseline,
                    previous: previous
                )
                previous = timing
            }

            if let byte = timings[.byte_search],
               let memchr = timings[.memchr_search],
               let currentNoop = timings[.current_noop],
               let currentCallback = timings[.current_callback],
               let localStats = timings[.callback_stats],
               let localMemchr = timings[.memchr_callback_stats]
            {
                print("  derived")
                print(
                    "    memchr search / byte search: "
                    + scannerProbeRatio(
                        memchr.medianNanoseconds,
                        byte.medianNanoseconds
                    )
                )
                print(
                    "    local memchr-callback / local byte-callback+stats: "
                    + scannerProbeRatio(
                        localMemchr.medianNanoseconds,
                        localStats.medianNanoseconds
                    )
                )
                print(
                    "    production callback body delta: "
                    + scannerProbeDeltaPerFragment(
                        later: currentCallback,
                        earlier: currentNoop
                    )
                )
            }

            print("")
        }

        print("interpretation guardrails:")
        print("  negative incremental deltas mean the neighboring local variants optimized differently; do not treat the table as perfectly additive.")
        print("  compare profile sensitivity: sparse lines emphasize delimiter search; short lines emphasize fragment/callback machinery.")
        print("  production current/* rows remain the authoritative cost of ByteLineScanner itself.")
        print("")
    }
}

private extension TestIO {
    static func scannerProbeRun(
        stage: ScannerProbeStage,
        pattern: [UInt8],
        totalByteCount: Int,
        capacity: BufferCapacity
    ) throws -> ScannerProbeResult {
        switch stage {
        case .byte_search:
            return try scannerProbeSearchOnly(
                pattern: pattern,
                totalByteCount: totalByteCount,
                capacity: capacity,
                useMemchr: false
            )

        case .memchr_search:
            return try scannerProbeSearchOnly(
                pattern: pattern,
                totalByteCount: totalByteCount,
                capacity: capacity,
                useMemchr: true
            )

        case .state_only:
            return try scannerProbeLocalSemanticScan(
                pattern: pattern,
                totalByteCount: totalByteCount,
                capacity: capacity,
                useMemchr: false,
                metadata: false,
                callback: false,
                statistics: false
            )

        case .metadata_only:
            return try scannerProbeLocalSemanticScan(
                pattern: pattern,
                totalByteCount: totalByteCount,
                capacity: capacity,
                useMemchr: false,
                metadata: true,
                callback: false,
                statistics: false
            )

        case .callback_no_stats:
            return try scannerProbeLocalSemanticScan(
                pattern: pattern,
                totalByteCount: totalByteCount,
                capacity: capacity,
                useMemchr: false,
                metadata: true,
                callback: true,
                statistics: false
            )

        case .callback_stats:
            return try scannerProbeLocalSemanticScan(
                pattern: pattern,
                totalByteCount: totalByteCount,
                capacity: capacity,
                useMemchr: false,
                metadata: true,
                callback: true,
                statistics: true
            )

        case .memchr_callback_stats:
            return try scannerProbeLocalSemanticScan(
                pattern: pattern,
                totalByteCount: totalByteCount,
                capacity: capacity,
                useMemchr: true,
                metadata: true,
                callback: true,
                statistics: true
            )

        case .current_noop:
            return try scannerProbeCurrentScanner(
                pattern: pattern,
                totalByteCount: totalByteCount,
                capacity: capacity,
                observeFragments: false
            )

        case .current_callback:
            return try scannerProbeCurrentScanner(
                pattern: pattern,
                totalByteCount: totalByteCount,
                capacity: capacity,
                observeFragments: true
            )
        }
    }

    static func scannerProbeSource(
        pattern: [UInt8],
        totalByteCount: Int,
        capacity: BufferCapacity
    ) -> Source {
        Source(
            ScannerProbeBackend(
                pattern: pattern,
                totalByteCount: totalByteCount,
                maximumChunkSize: capacity.value
            ),
            bufferCapacity: capacity
        )
    }

    static func scannerProbeSearchOnly(
        pattern: [UInt8],
        totalByteCount: Int,
        capacity: BufferCapacity,
        useMemchr: Bool
    ) throws -> ScannerProbeResult {
        var source = scannerProbeSource(
            pattern: pattern,
            totalByteCount: totalByteCount,
            capacity: capacity
        )

        var bytes: UInt64 = 0
        var lineFeeds: UInt64 = 0

        while true {
            switch try source.prepare() {
            case .bytes:
                let count = source.bufferedByteCount
                lineFeeds += source.withBytes {
                    if useMemchr {
                        scannerProbeCountLineFeedsMemchr(
                            $0
                        )
                    } else {
                        scannerProbeCountLineFeedsByteLoop(
                            $0
                        )
                    }
                }
                try source.consume(
                    count
                )
                bytes += UInt64(count)

            case .end:
                return .init(
                    byteCount: bytes,
                    lineFeedCount: lineFeeds,
                    fragmentCount: lineFeeds,
                    checksum: 0
                )

            case .unavailable:
                throw TestFailure(
                    message: "scanner probe Source became unavailable"
                )

            case .buffer_full:
                throw TestFailure(
                    message: "scanner probe Source unexpectedly buffer-full"
                )
            }
        }
    }

    static func scannerProbeLocalSemanticScan(
        pattern: [UInt8],
        totalByteCount: Int,
        capacity: BufferCapacity,
        useMemchr: Bool,
        metadata: Bool,
        callback: Bool,
        statistics: Bool
    ) throws -> ScannerProbeResult {
        var source = scannerProbeSource(
            pattern: pattern,
            totalByteCount: totalByteCount,
            capacity: capacity
        )

        var lineNumber: UInt64 = 1
        var lineStartOffset: UInt64 = 0
        var absoluteOffset: UInt64 = 0
        var currentLineHasBytes = false

        var bytesExamined: UInt64 = 0
        var fragments: UInt64 = 0
        var completedLines: UInt64 = 0
        var checksum: UInt64 = 0

        while true {
            switch try source.prepare() {
            case .bytes:
                let readableCount = source.bufferedByteCount

                var localLineNumber = lineNumber
                var localLineStartOffset = lineStartOffset
                var localAbsoluteOffset = absoluteOffset
                var localCurrentLineHasBytes = currentLineHasBytes
                var localFragments = fragments
                var localCompletedLines = completedLines
                var localChecksum = checksum

                source.withBytes { readable in
                    var fragmentStart = 0

                    while fragmentStart < readable.count {
                        let found: Int?

                        if useMemchr {
                            found = scannerProbeFindLineFeed(
                                readable,
                                from: fragmentStart
                            )
                        } else {
                            found = scannerProbeFindLineFeedByteLoop(
                                readable,
                                from: fragmentStart
                            )
                        }

                        guard let index = found else {
                            let count = readable.count - fragmentStart

                            if count > 0 {
                                if statistics {
                                    localFragments += 1
                                }

                                if metadata {
                                    let start = localAbsoluteOffset
                                    let end = start + UInt64(count)
                                    let fragment = ScannerProbeFragment(
                                        lineNumber: localLineNumber,
                                        lineStartOffset: localLineStartOffset,
                                        byteRange: start..<end,
                                        byteCount: count,
                                        ending: .none
                                    )

                                    if callback {
                                        localChecksum &+= scannerProbeObserve(
                                            fragment
                                        )
                                    } else {
                                        localChecksum &+= scannerProbeMetadataChecksum(
                                            fragment
                                        )
                                    }
                                }

                                localAbsoluteOffset += UInt64(count)
                                localCurrentLineHasBytes = true
                            }

                            break
                        }

                        let count = index - fragmentStart

                        if statistics {
                            localFragments += 1
                            localCompletedLines += 1
                        }

                        if metadata {
                            let start = localAbsoluteOffset
                            let end = start + UInt64(count)
                            let fragment = ScannerProbeFragment(
                                lineNumber: localLineNumber,
                                lineStartOffset: localLineStartOffset,
                                byteRange: start..<end,
                                byteCount: count,
                                ending: .line_feed
                            )

                            if callback {
                                localChecksum &+= scannerProbeObserve(
                                    fragment
                                )
                            } else {
                                localChecksum &+= scannerProbeMetadataChecksum(
                                    fragment
                                )
                            }
                        }

                        localAbsoluteOffset += UInt64(count + 1)
                        localLineNumber += 1
                        localLineStartOffset = localAbsoluteOffset
                        localCurrentLineHasBytes = false
                        fragmentStart = index + 1
                    }
                }

                try source.consume(
                    readableCount
                )

                if statistics {
                    bytesExamined += UInt64(readableCount)
                }

                lineNumber = localLineNumber
                lineStartOffset = localLineStartOffset
                absoluteOffset = localAbsoluteOffset
                currentLineHasBytes = localCurrentLineHasBytes
                fragments = localFragments
                completedLines = localCompletedLines
                checksum = localChecksum

            case .end:
                if currentLineHasBytes {
                    if statistics {
                        fragments += 1
                        completedLines += 1
                    }

                    if metadata {
                        let fragment = ScannerProbeFragment(
                            lineNumber: lineNumber,
                            lineStartOffset: lineStartOffset,
                            byteRange: absoluteOffset..<absoluteOffset,
                            byteCount: 0,
                            ending: .end
                        )

                        if callback {
                            checksum &+= scannerProbeObserve(
                                fragment
                            )
                        } else {
                            checksum &+= scannerProbeMetadataChecksum(
                                fragment
                            )
                        }
                    }
                }

                let lineFeeds = lineNumber - 1

                return .init(
                    byteCount: statistics ? bytesExamined : absoluteOffset,
                    lineFeedCount: lineFeeds,
                    fragmentCount: statistics ? fragments : lineFeeds,
                    checksum: metadata ? checksum : 0
                )

            case .unavailable:
                throw TestFailure(
                    message: "scanner semantic probe Source became unavailable"
                )

            case .buffer_full:
                throw TestFailure(
                    message: "scanner semantic probe Source unexpectedly buffer-full"
                )
            }
        }
    }

    static func scannerProbeCurrentScanner(
        pattern: [UInt8],
        totalByteCount: Int,
        capacity: BufferCapacity,
        observeFragments: Bool
    ) throws -> ScannerProbeResult {
        var scanner = ByteLineScanner(
            source: scannerProbeSource(
                pattern: pattern,
                totalByteCount: totalByteCount,
                capacity: capacity
            )
        )

        var checksum: UInt64 = 0

        while true {
            let result = try scanner.scan { fragment in
                if observeFragments {
                    checksum &+= scannerProbeObserveCurrent(
                        fragment
                    )
                }

                return .continue
            }

            switch result {
            case .end:
                let statistics = scanner.statistics

                return .init(
                    byteCount: statistics.bytesExamined,
                    lineFeedCount: statistics.completedLineCount,
                    fragmentCount: statistics.fragmentCount,
                    checksum: observeFragments ? checksum : 0
                )

            case .stopped:
                throw TestFailure(
                    message: "current scanner probe unexpectedly stopped"
                )

            case .unavailable:
                throw TestFailure(
                    message: "current scanner probe became unavailable"
                )
            }
        }
    }

    static func scannerProbeCheckSemanticEquivalence(
        values: [ScannerProbeStage: ScannerProbeResult],
        profile: ScannerProbeProfile
    ) throws {
        guard let byteSearch = values[.byte_search],
              let memchrSearch = values[.memchr_search],
              let local = values[.callback_stats],
              let localMemchr = values[.memchr_callback_stats],
              let current = values[.current_callback]
        else {
            throw TestFailure(
                message: "missing scanner probe values for \(profile.label)"
            )
        }

        try expectEqual(
            memchrSearch.byteCount,
            byteSearch.byteCount,
            "\(profile.label) memchr byte count"
        )
        try expectEqual(
            memchrSearch.lineFeedCount,
            byteSearch.lineFeedCount,
            "\(profile.label) memchr LF count"
        )
        try expectEqual(
            local.byteCount,
            byteSearch.byteCount,
            "\(profile.label) local scanner byte count"
        )
        try expectEqual(
            local.lineFeedCount,
            byteSearch.lineFeedCount,
            "\(profile.label) local scanner LF count"
        )
        try expectEqual(
            localMemchr,
            local,
            "\(profile.label) memchr semantic scanner"
        )
        try expectEqual(
            current,
            local,
            "\(profile.label) current scanner"
        )
    }

    static func scannerProbePattern(
        profile: ScannerProbeProfile,
        byteCount: Int
    ) -> [UInt8] {
        precondition(byteCount > 0)

        var bytes = Array(
            repeating: UInt8(ascii: "a"),
            count: byteCount
        )

        let stride = profile.lineStride

        for index in bytes.indices {
            bytes[index] = UInt8(
                97 + (index % 26)
            )

            if (index + 1) % stride == 0 {
                bytes[index] = 0x0A
            }
        }

        // Keep the repeated pattern semantically closed so every logical sample ends on LF.
        bytes[bytes.count - 1] = 0x0A

        return bytes
    }

    static func scannerProbeInterleavedOrder(
        round: Int,
        profileIndex: Int
    ) -> [ScannerProbeStage] {
        let all = ScannerProbeStage.allCases
        let shift = (round * 5 + profileIndex * 3) % all.count

        var ordered: [ScannerProbeStage] = []
        ordered.reserveCapacity(all.count)

        for index in all.indices {
            ordered.append(
                all[(index + shift) % all.count]
            )
        }

        if round % 2 == 1 {
            ordered.reverse()
        }

        return ordered
    }

    static func scannerProbePrintTiming(
        stage: ScannerProbeStage,
        timing: ScannerProbeTiming,
        baseline: ScannerProbeTiming,
        previous: ScannerProbeTiming?
    ) {
        let baselineRatio =
            Double(timing.medianNanoseconds)
            / Double(max(UInt64(1), baseline.medianNanoseconds))

        let priorText: String

        if let previous {
            let priorRatio =
                Double(timing.medianNanoseconds)
                / Double(max(UInt64(1), previous.medianNanoseconds))

            let delta =
                Int64(timing.medianNanoseconds)
                - Int64(previous.medianNanoseconds)
            let perLF =
                Double(delta)
                / Double(max(UInt64(1), timing.value.lineFeedCount))

            priorText =
                "vs prior "
                + String(format: "%.3fx", priorRatio)
                + " · "
                + String(format: "%+.2f ns/LF", perLF)
        } else {
            priorText = "baseline"
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
            + "] · "
            + priorText
            + " · vs byte-search "
            + String(format: "%.3fx", baselineRatio)
        )
    }

    static func scannerProbeRatio(
        _ numerator: UInt64,
        _ denominator: UInt64
    ) -> String {
        String(
            format: "%.3fx",
            Double(numerator) / Double(max(UInt64(1), denominator))
        )
    }

    static func scannerProbeDeltaPerFragment(
        later: ScannerProbeTiming,
        earlier: ScannerProbeTiming
    ) -> String {
        let delta =
            Int64(later.medianNanoseconds)
            - Int64(earlier.medianNanoseconds)
        let perFragment =
            Double(delta)
            / Double(max(UInt64(1), later.value.fragmentCount))

        return String(
            format: "%+.2f ns/fragment",
            perFragment
        )
    }

    @inline(__always)
    static func scannerProbeCountLineFeedsByteLoop(
        _ bytes: UnsafeRawBufferPointer
    ) -> UInt64 {
        var count: UInt64 = 0

        for byte in bytes where byte == 0x0A {
            count += 1
        }

        return count
    }

    static func scannerProbeCountLineFeedsMemchr(
        _ bytes: UnsafeRawBufferPointer
    ) -> UInt64 {
        var count: UInt64 = 0
        var offset = 0

        while let found = scannerProbeFindLineFeed(
            bytes,
            from: offset
        ) {
            count += 1
            offset = found + 1
        }

        return count
    }

    @inline(__always)
    static func scannerProbeFindLineFeedByteLoop(
        _ bytes: UnsafeRawBufferPointer,
        from start: Int
    ) -> Int? {
        guard start < bytes.count else {
            return nil
        }

        var index = start

        while index < bytes.count {
            if bytes[index] == 0x0A {
                return index
            }

            index += 1
        }

        return nil
    }

    static func scannerProbeFindLineFeed(
        _ bytes: UnsafeRawBufferPointer,
        from start: Int
    ) -> Int? {
        guard start < bytes.count,
              let base = bytes.baseAddress
        else {
            return nil
        }

        let searchBase = base.advanced(
            by: start
        )
        let searchCount = bytes.count - start

        #if canImport(Darwin)
        let found = Darwin.memchr(
            searchBase,
            Int32(0x0A),
            searchCount
        )
        #elseif canImport(Glibc)
        let found = Glibc.memchr(
            searchBase,
            Int32(0x0A),
            searchCount
        )
        #endif

        guard let found else {
            return nil
        }

        return base.distance(
            to: UnsafeRawPointer(found)
        )
    }

    @inline(__always)
    static func scannerProbeMetadataChecksum(
        _ fragment: ScannerProbeFragment
    ) -> UInt64 {
        var value = fragment.lineNumber
        value &+= fragment.lineStartOffset
        value &+= fragment.byteRange.lowerBound
        value &+= fragment.byteRange.upperBound
        value &+= UInt64(fragment.byteCount)

        switch fragment.ending {
        case .none:
            value &+= 1
        case .line_feed:
            value &+= 2
        case .end:
            value &+= 3
        }

        return value
    }

    @inline(never)
    static func scannerProbeObserve(
        _ fragment: ScannerProbeFragment
    ) -> UInt64 {
        scannerProbeMetadataChecksum(
            fragment
        )
    }

    @inline(never)
    static func scannerProbeObserveCurrent(
        _ fragment: ByteLineFragment
    ) -> UInt64 {
        var value = fragment.lineNumber
        value &+= fragment.lineStartOffset
        value &+= fragment.byteRange.lowerBound
        value &+= fragment.byteRange.upperBound
        value &+= UInt64(fragment.bytes.count)

        switch fragment.ending {
        case .none:
            value &+= 1
        case .line_feed:
            value &+= 2
        case .end:
            value &+= 3
        }

        return value
    }
}
