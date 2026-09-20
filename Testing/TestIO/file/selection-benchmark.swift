import Dispatch
import IO
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    static func testSystemFileSource() throws {
        let url = temporaryURL(name: "system-file-source")
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = Array("alpha\nβeta\n🐕\nomega".utf8)
        try Data(expected).write(to: url)

        var source = Source(
            try SystemFileSource(path: url.path),
            bufferCapacity: try BufferCapacity(5)
        )
        var actual: [UInt8] = []
        var scratch = Array(repeating: UInt8.zero, count: 3)

        readLoop: while true {
            let result = try scratch.withUnsafeMutableBytes { output in
                try source.read(into: output)
            }

            switch result {
            case .bytes(let count):
                actual.append(contentsOf: scratch.prefix(count.value))

            case .end:
                break readLoop

            case .unavailable:
                throw TestFailure(
                    message: "regular file unexpectedly became unavailable"
                )

            case .buffer_full:
                throw TestFailure(
                    message: "copying read unexpectedly reported a full Source buffer"
                )

            case .empty:
                throw TestFailure(
                    message: "non-empty scratch buffer unexpectedly produced .empty"
                )
            }
        }

        guard actual == expected else {
            throw TestFailure(
                message: "system file bytes differ from expected payload"
            )
        }

        guard source.statistics.refilledByteCount == UInt64(expected.count) else {
            throw TestFailure(
                message: "system file byte counter is incorrect"
            )
        }

        guard source.statistics.refillCallCount > 1 else {
            throw TestFailure(
                message: "small Source buffer should require multiple read(2) syscalls"
            )
        }
    }

    static func runSelectionBenchmarks(
        verbose: Bool,
        heavy: Bool
    ) throws {
        let fixtureLineCount = heavy ? 1_000_000 : 300_000
        let iterations = heavy ? 3 : 5
        let capacity = BufferCapacity.default

        let fixture = try SelectionBenchmarkFixture.make(
            lineCount: fixtureLineCount
        )
        defer {
            try? FileManager.default.removeItem(
                at: fixture.url
            )
        }

        let scenarios = selectionScenarios(
            lineCount: fixtureLineCount
        )

        print("")
        print("selection benchmark")
        print(
            "fixture: \(fixtureLineCount) lines · "
            + formatBytes(
                UInt64(fixture.byteCount)
            )
        )
        print(
            "iterations: \(iterations) · streaming buffer: "
            + formatBytes(
                UInt64(capacity.value)
            )
        )
        print("timings are warm-cache medians; isolated workers below measure peak RSS.")
        print("")
        print("strategies:")
        print("  data       Data(contentsOf:) → String → split → select")
        print("  mapped     Data(mappedIfSafe) → String → split → select")
        print("  filehandle FileHandle chunks → byte newline scan → decode selected lines")
        print("  posix      direct read(2) chunks → byte-at-a-time selection scanner")
        print("  expio      SystemFileSource → Source → ByteLineScanner → fragment selection")
        print("")

        for scenario in scenarios {
            try runBenchmarkScenario(
                scenario,
                fixture: fixture,
                capacity: capacity,
                iterations: iterations,
                includeIsolatedRSS: verbose
            )
        }

        if verbose {
            try runBufferSweep(
                fixture: fixture,
                iterations: max(
                    2,
                    iterations - 1
                )
            )
        }

        try runIOOverheadBenchmarks(
            fixture: fixture,
            iterations: max(
                3,
                iterations
            ),
            heavy: heavy
        )

        print("")
        print("metric notes:")
        print("  read(2) syscall counts are exact for posix and expio.")
        print("  FileHandle reports public read API calls; Foundation may perform different internal syscalls.")
        print("  Data/mapped syscall counts are intentionally n/a because Foundation hides that boundary.")
        print("  selected payload bytes measure semantic output; selected-copy bytes count explicit line-assembly copies.")
        print("  posix and expio selection rows use different scanner cores; use the I/O decomposition for abstraction cost.")
        print("  peak RSS captures actual whole-process retention.")
    }

    static func runSelectionBenchmarkWorker(
        arguments: [String]
    ) throws {
        guard arguments.count == 5,
              arguments[0] == "--benchmark-worker",
              let strategy = SelectionStrategy(
                rawValue: arguments[1]
              ),
              let capacityValue = Int(
                arguments[4]
              )
        else {
            throw TestFailure(
                message: "invalid benchmark worker arguments"
            )
        }

        let url = URL(
            fileURLWithPath: arguments[2]
        )
        let ranges = try decodeRanges(
            arguments[3]
        )
        let capacity = try BufferCapacity(
            capacityValue
        )

        let started = DispatchTime.now().uptimeNanoseconds
        let measurement = try runSelectionStrategy(
            strategy,
            url: url,
            ranges: ranges,
            capacity: capacity
        )
        let ended = DispatchTime.now().uptimeNanoseconds

        let report = BenchmarkWorkerReport(
            strategy: strategy.rawValue,
            elapsedNanoseconds: ended - started,
            peakMemoryBytes: peakMemoryBytes(),
            peakMemoryKind: peakMemoryKind(),
            lineCount: measurement.lines.count,
            bytesFetched: measurement.bytesFetched,
            bytesExamined: measurement.bytesExamined,
            selectedPayloadBytes: measurement.selectedPayloadBytes,
            selectedByteCopyCount:
                measurement.selectedByteCopyCount,
            peakSelectedLineByteCount:
                measurement.peakSelectedLineByteCount,
            peakSourceBufferedByteCount:
                measurement.peakSourceBufferedByteCount,
            readCallCount: measurement.readCallCount,
            readCallKind: measurement.readCallKind
        )

        let encoded = try JSONEncoder().encode(
            report
        )

        guard let line = String(
            data: encoded,
            encoding: .utf8
        ) else {
            throw TestFailure(
                message: "could not encode worker report"
            )
        }

        print(line)
    }
}

enum SelectionStrategy:
    String,
    CaseIterable,
    Hashable
{
    case data
    case mapped
    case filehandle
    case posix
    case expio

    var displayName: String {
        switch self {
        case .data:
            "data"

        case .mapped:
            "mapped"

        case .filehandle:
            "filehandle"

        case .posix:
            "posix"

        case .expio:
            "expio"
        }
    }
}

struct BenchmarkSelectedLine: Equatable {
    let number: Int
    let text: String
}

struct SelectionMeasurement {
    let lines: [BenchmarkSelectedLine]
    let byteRanges: [Range<UInt64>]
    let bytesFetched: UInt64
    let bytesExamined: UInt64
    let selectedPayloadBytes: UInt64
    let selectedByteCopyCount: UInt64
    let peakSelectedLineByteCount: Int
    let peakSourceBufferedByteCount: Int
    let readCallCount: Int?
    let readCallKind: String
    let materializedLineCount: Int?
}

struct LineSelectionResult {
    let lines: [BenchmarkSelectedLine]
    let byteRanges: [Range<UInt64>]
    let bytesExamined: UInt64
    let selectedPayloadBytes: UInt64
    let selectedByteCopyCount: UInt64
    let peakSelectedLineByteCount: Int
}

struct BenchmarkTimingSummary {
    let strategy: SelectionStrategy
    let medianNanoseconds: UInt64
    let minimumNanoseconds: UInt64
    let maximumNanoseconds: UInt64
    let measurement: SelectionMeasurement
}

struct Timed<Value> {
    let value: Value
    let medianNanoseconds: UInt64
    let minimumNanoseconds: UInt64
    let maximumNanoseconds: UInt64
}

struct SelectionBenchmarkScenario {
    let name: String
    let ranges: [ClosedRange<Int>]
}

struct SelectionBenchmarkFixture {
    let url: URL
    let lineCount: Int
    let byteCount: Int

    static func make(
        lineCount: Int
    ) throws -> Self {
        let url = TestIO.temporaryURL(
            name: "selection-benchmark"
        )

        _ = FileManager.default.createFile(
            atPath: url.path,
            contents: nil
        )

        let handle = try FileHandle(
            forWritingTo: url
        )
        defer {
            try? handle.close()
        }

        let chunkTarget = 1 * 1024 * 1024
        var chunk: [UInt8] = []
        chunk.reserveCapacity(
            chunkTarget + 256
        )
        var byteCount = 0

        for lineNumber in 1...lineCount {
            let line =
                "\(lineNumber)"
                + "|abcdefghijklmnopqrstuvwxyz"
                + "|ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                + "|0123456789"
                + "|café"
                + "|🐕"
                + "|selection-benchmark-payload\n"

            chunk.append(
                contentsOf: line.utf8
            )

            if chunk.count >= chunkTarget {
                try handle.write(
                    contentsOf: Data(
                        chunk
                    )
                )
                byteCount += chunk.count
                chunk.removeAll(
                    keepingCapacity: true
                )
            }
        }

        if !chunk.isEmpty {
            try handle.write(
                contentsOf: Data(
                    chunk
                )
            )
            byteCount += chunk.count
        }

        return .init(
            url: url,
            lineCount: lineCount,
            byteCount: byteCount
        )
    }
}

struct RawLineSelectionAccumulator {
    private let ranges: [ClosedRange<Int>]
    private let finalRequestedLine: Int?

    private(set) var selected: [BenchmarkSelectedLine]
    private(set) var selectedByteRanges: [Range<UInt64>]
    private(set) var bytesExamined: UInt64
    private(set) var selectedPayloadBytes: UInt64
    private(set) var selectedByteCopyCount: UInt64
    private(set) var peakSelectedLineByteCount: Int
    private(set) var isFinished: Bool

    private var selectedLineBytes: [UInt8]
    private var currentLine: Int
    private var currentLineStartOffset: UInt64
    private var rangeIndex: Int
    private var currentLineStarted: Bool

    init(
        ranges: [ClosedRange<Int>]
    ) {
        let normalized = TestIO.normalize(
            ranges
        )

        self.ranges = normalized
        self.finalRequestedLine =
            normalized.last?.upperBound
        self.selected = []
        self.selectedByteRanges = []
        self.bytesExamined = 0
        self.selectedPayloadBytes = 0
        self.selectedByteCopyCount = 0
        self.peakSelectedLineByteCount = 0
        self.isFinished = normalized.isEmpty

        self.selectedLineBytes = []
        self.currentLine = 1
        self.currentLineStartOffset = 0
        self.rangeIndex = 0
        self.currentLineStarted = false
    }

    mutating func consume(
        _ bytes: UnsafeRawBufferPointer
    ) -> Int {
        guard !isFinished else {
            return 0
        }

        var processed = 0

        while processed < bytes.count,
              !isFinished
        {
            let byte = bytes[processed]
            let absoluteOffset = bytesExamined

            processed += 1
            bytesExamined += 1

            if byte == 0x0A {
                finalizeCurrentLine(
                    endOffset: absoluteOffset
                )

                currentLineStarted = false
                currentLine += 1
                currentLineStartOffset =
                    absoluteOffset + 1

                while rangeIndex < ranges.count,
                      currentLine
                        > ranges[rangeIndex].upperBound
                {
                    rangeIndex += 1
                }

                if let finalRequestedLine,
                   currentLine > finalRequestedLine
                {
                    isFinished = true
                }
            } else {
                currentLineStarted = true

                if currentLineIsSelected {
                    selectedLineBytes.append(
                        byte
                    )
                    selectedByteCopyCount += 1
                    peakSelectedLineByteCount = max(
                        peakSelectedLineByteCount,
                        selectedLineBytes.count
                    )
                }
            }
        }

        return processed
    }

    mutating func finishAtEOF() {
        guard !isFinished else {
            return
        }

        if currentLineStarted {
            finalizeCurrentLine(
                endOffset: bytesExamined
            )
        }

        isFinished = true
    }

    var result: LineSelectionResult {
        .init(
            lines: selected,
            byteRanges: selectedByteRanges,
            bytesExamined: bytesExamined,
            selectedPayloadBytes:
                selectedPayloadBytes,
            selectedByteCopyCount:
                selectedByteCopyCount,
            peakSelectedLineByteCount:
                peakSelectedLineByteCount
        )
    }

    private var currentLineIsSelected: Bool {
        guard rangeIndex < ranges.count else {
            return false
        }

        return ranges[rangeIndex].contains(
            currentLine
        )
    }

    private mutating func finalizeCurrentLine(
        endOffset: UInt64
    ) {
        guard currentLineIsSelected else {
            selectedLineBytes.removeAll(
                keepingCapacity: true
            )
            return
        }

        var contentEndOffset = endOffset

        if selectedLineBytes.last == 0x0D {
            selectedLineBytes.removeLast()

            if contentEndOffset > currentLineStartOffset {
                contentEndOffset -= 1
            }
        }

        selected.append(
            .init(
                number: currentLine,
                text: String(
                    decoding: selectedLineBytes,
                    as: UTF8.self
                )
            )
        )

        selectedByteRanges.append(
            currentLineStartOffset
                ..< contentEndOffset
        )

        selectedPayloadBytes += UInt64(
            selectedLineBytes.count
        )

        selectedLineBytes.removeAll(
            keepingCapacity: true
        )
    }
}


struct LineSelectionAccumulator {
    private let ranges: [ClosedRange<Int>]
    private let finalRequestedLine: Int?

    private(set) var selected: [BenchmarkSelectedLine]
    private(set) var selectedByteRanges: [Range<UInt64>]
    private(set) var bytesExamined: UInt64
    private(set) var selectedPayloadBytes: UInt64
    private(set) var selectedByteCopyCount: UInt64
    private(set) var peakSelectedLineByteCount: Int
    private(set) var isFinished: Bool

    private var selectedLineBytes: [UInt8]
    private var rangeIndex: Int

    init(
        ranges: [ClosedRange<Int>]
    ) {
        let normalized = TestIO.normalize(
            ranges
        )

        self.ranges = normalized
        self.finalRequestedLine =
            normalized.last?.upperBound
        self.selected = []
        self.selectedByteRanges = []
        self.bytesExamined = 0
        self.selectedPayloadBytes = 0
        self.selectedByteCopyCount = 0
        self.peakSelectedLineByteCount = 0
        self.isFinished = normalized.isEmpty
        self.selectedLineBytes = []
        self.rangeIndex = 0
    }

    mutating func consume(
        _ fragment: ByteLineFragment
    ) -> ByteLineScanDirective {
        guard !isFinished else {
            return .stop
        }

        let lineNumber = Int(
            fragment.lineNumber
        )

        while rangeIndex < ranges.count,
              lineNumber > ranges[rangeIndex].upperBound
        {
            rangeIndex += 1
        }

        let selected = currentLineIsSelected(
            lineNumber
        )

        if selected,
           !fragment.bytes.isEmpty
        {
            selectedLineBytes.append(
                contentsOf: fragment.bytes
            )
            selectedByteCopyCount += UInt64(
                fragment.bytes.count
            )
            peakSelectedLineByteCount = max(
                peakSelectedLineByteCount,
                selectedLineBytes.count
            )
        }

        bytesExamined += UInt64(
            fragment.bytes.count
        )

        if fragment.ending == .line_feed {
            bytesExamined += 1
        }

        guard fragment.ending != .none else {
            return .continue
        }

        if selected {
            finalizeSelectedLine(
                lineNumber: lineNumber,
                lineStartOffset: fragment.lineStartOffset,
                endOffset: fragment.byteRange.upperBound
            )
        } else {
            selectedLineBytes.removeAll(
                keepingCapacity: true
            )
        }

        if let finalRequestedLine,
           lineNumber >= finalRequestedLine
        {
            isFinished = true
            return .stop
        }

        return .continue
    }

    mutating func finishAtEOF() {
        isFinished = true
    }

    var result: LineSelectionResult {
        .init(
            lines: selected,
            byteRanges: selectedByteRanges,
            bytesExamined: bytesExamined,
            selectedPayloadBytes:
                selectedPayloadBytes,
            selectedByteCopyCount:
                selectedByteCopyCount,
            peakSelectedLineByteCount:
                peakSelectedLineByteCount
        )
    }

    private func currentLineIsSelected(
        _ lineNumber: Int
    ) -> Bool {
        guard rangeIndex < ranges.count else {
            return false
        }

        return ranges[rangeIndex].contains(
            lineNumber
        )
    }

    private mutating func finalizeSelectedLine(
        lineNumber: Int,
        lineStartOffset: UInt64,
        endOffset: UInt64
    ) {
        var contentEndOffset = endOffset

        if selectedLineBytes.last == 0x0D {
            selectedLineBytes.removeLast()

            if contentEndOffset > lineStartOffset {
                contentEndOffset -= 1
            }
        }

        selected.append(
            .init(
                number: lineNumber,
                text: String(
                    decoding: selectedLineBytes,
                    as: UTF8.self
                )
            )
        )

        selectedByteRanges.append(
            lineStartOffset..<contentEndOffset
        )

        selectedPayloadBytes += UInt64(
            selectedLineBytes.count
        )

        selectedLineBytes.removeAll(
            keepingCapacity: true
        )
    }
}

struct BenchmarkWorkerReport: Codable {
    let strategy: String
    let elapsedNanoseconds: UInt64
    let peakMemoryBytes: UInt64
    let peakMemoryKind: String
    let lineCount: Int
    let bytesFetched: UInt64
    let bytesExamined: UInt64
    let selectedPayloadBytes: UInt64
    let selectedByteCopyCount: UInt64
    let peakSelectedLineByteCount: Int
    let peakSourceBufferedByteCount: Int
    let readCallCount: Int?
    let readCallKind: String
}

extension TestIO {
    static func runBenchmarkScenario(
        _ scenario: SelectionBenchmarkScenario,
        fixture: SelectionBenchmarkFixture,
        capacity: BufferCapacity,
        iterations: Int,
        includeIsolatedRSS: Bool
    ) throws {
        var signatures:
            [SelectionStrategy: UInt64] = [:]

        for strategy in SelectionStrategy.allCases {
            let check = try runSelectionStrategy(
                strategy,
                url: fixture.url,
                ranges: scenario.ranges,
                capacity: capacity
            )

            signatures[strategy] = selectionSignature(
                check.lines
            )
        }

        guard let reference = signatures[.data] else {
            preconditionFailure(
                "data correctness reference missing"
            )
        }

        for strategy in SelectionStrategy.allCases {
            guard signatures[strategy] == reference else {
                throw TestFailure(
                    message:
                        "selection correctness mismatch for "
                        + "\(scenario.name) / "
                        + strategy.rawValue
                )
            }
        }

        var summaries:
            [SelectionStrategy: BenchmarkTimingSummary] = [:]

        for strategy in SelectionStrategy.allCases {
            let timing = try measure(
                iterations: iterations
            ) {
                try runSelectionStrategy(
                    strategy,
                    url: fixture.url,
                    ranges: scenario.ranges,
                    capacity: capacity
                )
            }

            guard selectionSignature(
                timing.value.lines
            ) == reference
            else {
                throw TestFailure(
                    message:
                        "timed selection mismatch for "
                        + "\(scenario.name) / "
                        + strategy.rawValue
                )
            }

            summaries[strategy] = .init(
                strategy: strategy,
                medianNanoseconds:
                    timing.medianNanoseconds,
                minimumNanoseconds:
                    timing.minimumNanoseconds,
                maximumNanoseconds:
                    timing.maximumNanoseconds,
                measurement: timing.value
            )
        }

        print(
            "\(scenario.name) · correctness verified across "
            + "\(SelectionStrategy.allCases.count) strategies"
        )

        for strategy in SelectionStrategy.allCases {
            guard let summary = summaries[strategy] else {
                continue
            }

            printTimingSummary(
                summary
            )
        }

        if let data = summaries[.data],
           let expio = summaries[.expio]
        {
            let ratio =
                Double(data.medianNanoseconds)
                / Double(
                    max(
                        1,
                        expio.medianNanoseconds
                    )
                )

            print(
                "  data/expio time ratio: "
                + String(
                    format: "%.2fx",
                    ratio
                )
            )
        }

        if let posix = summaries[.posix],
           let expio = summaries[.expio]
        {
            let ratio =
                Double(expio.medianNanoseconds)
                / Double(
                    max(
                        1,
                        posix.medianNanoseconds
                    )
                )

            print(
                "  expio/posix end-to-end ratio: "
                + String(
                    format: "%.3fx",
                    ratio
                )
                + " (scanner cores differ; not an abstraction-overhead measurement)"
            )
        }

        if includeIsolatedRSS {
            print("  isolated peak memory")

            for strategy in SelectionStrategy.allCases {
                let report = try runIsolatedWorker(
                    strategy: strategy,
                    fixture: fixture,
                    ranges: scenario.ranges,
                    capacity: capacity
                )

                print(
                    "    "
                    + padded(
                        strategy.displayName,
                        width: 10
                    )
                    + " "
                    + formatBytes(
                        report.peakMemoryBytes
                    )
                    + " ("
                    + report.peakMemoryKind
                    + ") · "
                    + reportReadCount(
                        report.readCallCount,
                        kind: report.readCallKind
                    )
                )
            }
        }

        print("")
    }

    static func runSelectionStrategy(
        _ strategy: SelectionStrategy,
        url: URL,
        ranges: [ClosedRange<Int>],
        capacity: BufferCapacity
    ) throws -> SelectionMeasurement {
        switch strategy {
        case .data:
            return try dataSelection(
                url: url,
                ranges: ranges,
                mapped: false
            )

        case .mapped:
            return try dataSelection(
                url: url,
                ranges: ranges,
                mapped: true
            )

        case .filehandle:
            return try fileHandleSelection(
                url: url,
                ranges: ranges,
                capacity: capacity
            )

        case .posix:
            return try directPOSIXSelection(
                path: url.path,
                ranges: ranges,
                capacity: capacity
            )

        case .expio:
            return try experimentSelection(
                path: url.path,
                ranges: ranges,
                capacity: capacity
            )
        }
    }

    static func dataSelection(
        url: URL,
        ranges: [ClosedRange<Int>],
        mapped: Bool
    ) throws -> SelectionMeasurement {
        let data: Data

        if mapped {
            data = try Data(
                contentsOf: url,
                options: .mappedIfSafe
            )
        } else {
            data = try Data(
                contentsOf: url
            )
        }

        let text = String(
            decoding: data,
            as: UTF8.self
        )

        var lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )

        if text.last == "\n",
           lines.last?.isEmpty == true
        {
            lines.removeLast()
        }

        let normalized = normalize(
            ranges
        )

        var selected:
            [BenchmarkSelectedLine] = []

        var selectedPayloadBytes: UInt64 = 0
        var peakLineBytes = 0

        for range in normalized {
            guard range.lowerBound <= lines.count else {
                break
            }

            let upper = min(
                range.upperBound,
                lines.count
            )

            for lineNumber
                in range.lowerBound...upper
            {
                var line = lines[
                    lineNumber - 1
                ]

                if line.last == "\r" {
                    line = line.dropLast()
                }

                let value = String(
                    line
                )
                let byteCount = value.utf8.count

                selectedPayloadBytes += UInt64(
                    byteCount
                )
                peakLineBytes = max(
                    peakLineBytes,
                    byteCount
                )

                selected.append(
                    .init(
                        number: lineNumber,
                        text: value
                    )
                )
            }
        }

        return .init(
            lines: selected,
            byteRanges: [],
            bytesFetched: UInt64(
                data.count
            ),
            bytesExamined: UInt64(
                data.count
            ),
            selectedPayloadBytes:
                selectedPayloadBytes,
            selectedByteCopyCount:
                selectedPayloadBytes,
            peakSelectedLineByteCount:
                peakLineBytes,
            peakSourceBufferedByteCount: 0,
            readCallCount: nil,
            readCallKind:
                mapped
                ? "Foundation mapped internals"
                : "Foundation Data internals",
            materializedLineCount: lines.count
        )
    }

    static func fileHandleSelection(
        url: URL,
        ranges: [ClosedRange<Int>],
        capacity: BufferCapacity
    ) throws -> SelectionMeasurement {
        let handle = try FileHandle(
            forReadingFrom: url
        )
        defer {
            try? handle.close()
        }

        var selector = RawLineSelectionAccumulator(
            ranges: ranges
        )
        var bytesFetched: UInt64 = 0
        var readCalls = 0

        while !selector.isFinished {
            let data = try handle.read(
                upToCount: capacity.value
            )

            readCalls += 1

            guard let data,
                  !data.isEmpty
            else {
                selector.finishAtEOF()
                break
            }

            bytesFetched += UInt64(
                data.count
            )

            data.withUnsafeBytes {
                _ = selector.consume(
                    $0
                )
            }
        }

        let result = selector.result

        return .init(
            lines: result.lines,
            byteRanges: result.byteRanges,
            bytesFetched: bytesFetched,
            bytesExamined:
                result.bytesExamined,
            selectedPayloadBytes:
                result.selectedPayloadBytes,
            selectedByteCopyCount:
                result.selectedByteCopyCount,
            peakSelectedLineByteCount:
                result.peakSelectedLineByteCount,
            peakSourceBufferedByteCount: 0,
            readCallCount: readCalls,
            readCallKind: "FileHandle reads",
            materializedLineCount: nil
        )
    }

    static func directPOSIXSelection(
        path: String,
        ranges: [ClosedRange<Int>],
        capacity: BufferCapacity
    ) throws -> SelectionMeasurement {
        let descriptor = path.withCString {
            benchmarkOpenReadOnly(
                $0
            )
        }

        guard descriptor >= 0 else {
            throw TestFailure(
                message:
                    "direct POSIX open failed: "
                    + "\(errno)"
            )
        }

        defer {
            _ = benchmarkClose(
                descriptor
            )
        }

        var selector = RawLineSelectionAccumulator(
            ranges: ranges
        )
        var storage = Array(
            repeating: UInt8.zero,
            count: capacity.value
        )
        var bytesFetched: UInt64 = 0
        var syscalls = 0

        readLoop: while !selector.isFinished {
            let result = storage.withUnsafeMutableBytes {
                buffer in
                benchmarkRead(
                    descriptor,
                    buffer.baseAddress,
                    buffer.count
                )
            }

            syscalls += 1

            if result > 0 {
                bytesFetched += UInt64(
                    result
                )

                storage.withUnsafeBytes {
                    raw in
                    let offered =
                        UnsafeRawBufferPointer(
                            start: raw.baseAddress,
                            count: result
                        )

                    _ = selector.consume(
                        offered
                    )
                }

                continue
            }

            if result == 0 {
                selector.finishAtEOF()
                break readLoop
            }

            if errno == EINTR {
                continue
            }

            throw TestFailure(
                message:
                    "direct POSIX read failed: "
                    + "\(errno)"
            )
        }

        let result = selector.result

        return .init(
            lines: result.lines,
            byteRanges: result.byteRanges,
            bytesFetched: bytesFetched,
            bytesExamined:
                result.bytesExamined,
            selectedPayloadBytes:
                result.selectedPayloadBytes,
            selectedByteCopyCount:
                result.selectedByteCopyCount,
            peakSelectedLineByteCount:
                result.peakSelectedLineByteCount,
            peakSourceBufferedByteCount:
                capacity.value,
            readCallCount: syscalls,
            readCallKind: "read(2) syscalls",
            materializedLineCount: nil
        )
    }

    static func experimentSelection(
        path: String,
        ranges: [ClosedRange<Int>],
        capacity: BufferCapacity
    ) throws -> SelectionMeasurement {
        let source = Source(
            try SystemFileSource(
                path: path
            ),
            bufferCapacity: capacity
        )

        let scan = try scanSourceSelection(
            source: consume source,
            ranges: ranges
        )

        return .init(
            lines: scan.result.lines,
            byteRanges:
                scan.result.byteRanges,
            bytesFetched:
                scan.statistics.source
                    .refilledByteCount,
            bytesExamined:
                scan.statistics.bytesExamined,
            selectedPayloadBytes:
                scan.result.selectedPayloadBytes,
            selectedByteCopyCount:
                scan.result.selectedByteCopyCount,
            peakSelectedLineByteCount:
                scan.result
                    .peakSelectedLineByteCount,
            peakSourceBufferedByteCount:
                scan.statistics
                    .peakSourceBufferedByteCount,
            readCallCount:
                Int(
                    scan.statistics.source
                        .refillCallCount
                ),
            readCallKind: "read(2) syscalls",
            materializedLineCount: nil
        )
    }

    static func scanSourceSelection(
        source: consuming Source,
        ranges: [ClosedRange<Int>]
    ) throws -> (
        result: LineSelectionResult,
        statistics: ByteLineScannerStatistics
    ) {
        var selector = LineSelectionAccumulator(
            ranges: ranges
        )
        var scanner = ByteLineScanner(
            source: consume source
        )

        let scanResult = try scanner.scan {
            fragment in
            selector.consume(
                fragment
            )
        }

        switch scanResult {
        case .end:
            selector.finishAtEOF()

        case .stopped:
            break

        case .unavailable:
            throw TestFailure(
                message:
                    "selection source unexpectedly "
                    + "became unavailable"
            )
        }

        return (
            selector.result,
            scanner.statistics
        )
    }

    static func normalize(
        _ ranges: [ClosedRange<Int>]
    ) -> [ClosedRange<Int>] {
        let sorted = ranges
            .filter {
                $0.lowerBound > 0
            }
            .sorted {
                lhs,
                rhs in
                if lhs.lowerBound
                    != rhs.lowerBound
                {
                    return lhs.lowerBound
                        < rhs.lowerBound
                }

                return lhs.upperBound
                    < rhs.upperBound
            }

        var result:
            [ClosedRange<Int>] = []

        for range in sorted {
            guard let last = result.last else {
                result.append(
                    range
                )
                continue
            }

            if range.lowerBound
                <= last.upperBound + 1
            {
                result[
                    result.count - 1
                ] = last.lowerBound...max(
                    last.upperBound,
                    range.upperBound
                )
            } else {
                result.append(
                    range
                )
            }
        }

        return result
    }

    static func selectionScenarios(
        lineCount: Int
    ) -> [SelectionBenchmarkScenario] {
        let middle = lineCount / 2
        let late = max(
            1,
            lineCount - 1_000
        )

        return [
            .init(
                name: "early-21-lines",
                ranges: [
                    10...30,
                ]
            ),
            .init(
                name: "middle-21-lines",
                ranges: [
                    middle...(middle + 20),
                ]
            ),
            .init(
                name: "late-21-lines",
                ranges: [
                    late...(late + 20),
                ]
            ),
            .init(
                name: "sparse-4x3-lines",
                ranges: [
                    10...12,
                    (lineCount / 4)...(lineCount / 4 + 2),
                    middle...(middle + 2),
                    late...(late + 2),
                ]
            ),
            .init(
                name: "full-file",
                ranges: [
                    1...lineCount,
                ]
            ),
        ]
    }

    static func measure<Value>(
        iterations: Int,
        _ body: () throws -> Value
    ) throws -> Timed<Value> {
        precondition(
            iterations > 0
        )

        var durations: [UInt64] = []
        durations.reserveCapacity(
            iterations
        )

        var value: Value?

        for _ in 0..<iterations {
            let started =
                DispatchTime.now()
                .uptimeNanoseconds

            let current = try body()

            let ended =
                DispatchTime.now()
                .uptimeNanoseconds

            durations.append(
                ended - started
            )
            value = current
        }

        durations.sort()

        guard let value else {
            preconditionFailure(
                "positive benchmark iteration "
                + "count must produce a value"
            )
        }

        return .init(
            value: value,
            medianNanoseconds:
                durations[
                    durations.count / 2
                ],
            minimumNanoseconds:
                durations[0],
            maximumNanoseconds:
                durations[
                    durations.count - 1
                ]
        )
    }

    static func selectionSignature(
        _ lines: [BenchmarkSelectedLine]
    ) -> UInt64 {
        var hash:
            UInt64 = 14695981039346656037

        func mix(
            _ byte: UInt8
        ) {
            hash ^= UInt64(
                byte
            )
            hash &*= 1099511628211
        }

        for line in lines {
            var number = UInt64(
                line.number
            )

            for _ in 0..<8 {
                mix(
                    UInt8(
                        truncatingIfNeeded:
                            number
                    )
                )
                number >>= 8
            }

            for byte in line.text.utf8 {
                mix(
                    byte
                )
            }

            mix(
                0x0A
            )
        }

        return hash
    }

    static func runIsolatedWorker(
        strategy: SelectionStrategy,
        fixture: SelectionBenchmarkFixture,
        ranges: [ClosedRange<Int>],
        capacity: BufferCapacity
    ) throws -> BenchmarkWorkerReport {
        let executable = URL(
            fileURLWithPath:
                CommandLine.arguments[0],
            relativeTo: URL(
                fileURLWithPath:
                    FileManager.default
                    .currentDirectoryPath
            )
        )
        .standardizedFileURL

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--benchmark-worker",
            strategy.rawValue,
            fixture.url.path,
            encodeRanges(
                ranges
            ),
            String(
                capacity.value
            ),
        ]

        let output = Pipe()
        let error = Pipe()

        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        let stdout = output.fileHandleForReading
            .readDataToEndOfFile()
        let stderr = error.fileHandleForReading
            .readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let message =
                String(
                    data: stderr,
                    encoding: .utf8
                )
                ?? "unknown worker error"

            throw TestFailure(
                message:
                    "benchmark worker failed: "
                    + message
            )
        }

        return try JSONDecoder().decode(
            BenchmarkWorkerReport.self,
            from: stdout
        )
    }

    static func encodeRanges(
        _ ranges: [ClosedRange<Int>]
    ) -> String {
        normalize(
            ranges
        )
        .map {
            "\($0.lowerBound):\($0.upperBound)"
        }
        .joined(
            separator: ","
        )
    }

    static func decodeRanges(
        _ encoded: String
    ) throws -> [ClosedRange<Int>] {
        guard !encoded.isEmpty else {
            return []
        }

        return try encoded
            .split(
                separator: ","
            )
            .map {
                component in
                let bounds = component.split(
                    separator: ":"
                )

                guard bounds.count == 2,
                      let lower = Int(
                        bounds[0]
                      ),
                      let upper = Int(
                        bounds[1]
                      ),
                      lower > 0,
                      lower <= upper
                else {
                    throw TestFailure(
                        message:
                            "invalid encoded range "
                            + String(
                                component
                            )
                    )
                }

                return lower...upper
            }
    }

    static func printTimingSummary(
        _ summary: BenchmarkTimingSummary
    ) {
        let measurement =
            summary.measurement

        let calls = reportReadCount(
            measurement.readCallCount,
            kind: measurement.readCallKind
        )

        print(
            "  "
            + padded(
                summary.strategy.displayName,
                width: 10
            )
            + " "
            + formatMilliseconds(
                milliseconds(
                    summary.medianNanoseconds
                )
            )
            + " ms · fetched "
            + formatBytes(
                measurement.bytesFetched
            )
            + " · examined "
            + formatBytes(
                measurement.bytesExamined
            )
            + " · selected "
            + formatBytes(
                measurement.selectedPayloadBytes
            )
            + " · explicit copies "
            + formatBytes(
                measurement.selectedByteCopyCount
            )
            + " · "
            + calls
        )

        if let materialized =
            measurement.materializedLineCount
        {
            print(
                "             materialized "
                + "\(materialized) lines"
            )
        }
    }

    static func runBufferSweep(
        fixture: SelectionBenchmarkFixture,
        iterations: Int
    ) throws {
        let line =
            fixture.lineCount / 2

        let ranges = [
            line...(line + 20),
        ]

        let capacities = [
            4 * 1024,
            16 * 1024,
            64 * 1024,
            256 * 1024,
        ]

        print("buffer sweep · middle-21-lines")

        for rawCapacity in capacities {
            let capacity =
                try BufferCapacity(
                    rawCapacity
                )

            let timing = try measure(
                iterations: iterations
            ) {
                try experimentSelection(
                    path: fixture.url.path,
                    ranges: ranges,
                    capacity: capacity
                )
            }

            print(
                "  "
                + formatBytes(
                    UInt64(
                        rawCapacity
                    )
                )
                + ": "
                + formatMilliseconds(
                    milliseconds(
                        timing.medianNanoseconds
                    )
                )
                + " ms · "
                + "\(timing.value.readCallCount ?? 0)"
                + " read(2) syscalls"
            )
        }

        print("")
    }

    static func temporaryURL(
        name: String
    ) -> URL {
        FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "tio-\(name)-"
                + "\(ProcessInfo.processInfo.processIdentifier)-"
                + UUID().uuidString
            )
    }

    static func milliseconds(
        _ nanoseconds: UInt64
    ) -> Double {
        Double(
            nanoseconds
        ) / 1_000_000
    }

    static func formatMilliseconds(
        _ value: Double
    ) -> String {
        String(
            format: "%.3f",
            value
        )
    }

    static func formatBytes(
        _ bytes: UInt64
    ) -> String {
        let value = Double(
            bytes
        )

        if bytes >= 1024 * 1024 {
            return String(
                format: "%.2f MiB",
                value
                    / Double(
                        1024 * 1024
                    )
            )
        }

        if bytes >= 1024 {
            return String(
                format: "%.2f KiB",
                value
                    / Double(
                        1024
                    )
            )
        }

        return "\(bytes) B"
    }

    static func padded(
        _ value: String,
        width: Int
    ) -> String {
        guard value.count < width else {
            return value
        }

        return value
            + String(
                repeating: " ",
                count: width - value.count
            )
    }

    static func reportReadCount(
        _ count: Int?,
        kind: String
    ) -> String {
        guard let count else {
            return "\(kind): n/a"
        }

        return "\(kind): \(count)"
    }

    static func peakMemoryKind() -> String {
        #if canImport(Darwin)
        return "lifetime max physical footprint"
        #elseif canImport(Glibc)
        return "VmHWM peak RSS"
        #endif
    }

    static func peakMemoryBytes() -> UInt64 {
        #if canImport(Darwin)
        var info = rusage_info_v4()

        let result = withUnsafeMutablePointer(
            to: &info
        ) {
            pointer -> Int32 in
            pointer.withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) {
                rebound in
                proc_pid_rusage(
                    getpid(),
                    Int32(
                        RUSAGE_INFO_V4
                    ),
                    rebound
                )
            }
        }

        guard result == 0 else {
            return 0
        }

        return info
            .ri_lifetime_max_phys_footprint
        #elseif canImport(Glibc)
        guard let status =
            try? String(
                contentsOfFile:
                    "/proc/self/status",
                encoding: .utf8
            )
        else {
            return 0
        }

        for line in status.split(
            separator: "\n"
        ) {
            guard line.hasPrefix(
                "VmHWM:"
            ) else {
                continue
            }

            let fields = line.split(
                whereSeparator: {
                    $0 == " "
                    || $0 == "\t"
                }
            )

            if fields.count >= 2,
               let kib = UInt64(
                fields[1]
               )
            {
                return kib * 1024
            }
        }

        return 0
        #endif
    }
}

@inline(__always)
private func benchmarkOpenReadOnly(
    _ path: UnsafePointer<CChar>
) -> Int32 {
    #if canImport(Darwin)
    Darwin.open(
        path,
        O_RDONLY
    )
    #elseif canImport(Glibc)
    Glibc.open(
        path,
        O_RDONLY
    )
    #endif
}

@inline(__always)
private func benchmarkRead(
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
private func benchmarkClose(
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
