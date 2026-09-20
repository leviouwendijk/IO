import IO
import Foundation

extension TestIO {
    static func testSelectionUnicodeFragmentation() throws {
        let fixture = makeUnicodeVerificationFixture()

        for capacityValue in 1...7 {
            for chunkValue in 1...7 {
                let backend = MemorySource(
                    bytes: fixture.bytes,
                    maximumChunkSize:
                        try PositiveByteCount(
                            chunkValue
                        )
                )

                let source = Source(
                    backend,
                    bufferCapacity:
                        try BufferCapacity(
                            capacityValue
                        )
                )

                let scan = try scanSourceSelection(
                    source: consume source,
                    ranges: [
                        1...fixture.lines.count,
                    ]
                )

                guard scan.result.lines
                    == fixture.lines
                else {
                    throw TestFailure(
                        message:
                            "unicode selection mismatch "
                            + "capacity=\(capacityValue) "
                            + "chunk=\(chunkValue)"
                    )
                }

                guard scan.result.byteRanges
                    == fixture.byteRanges
                else {
                    throw TestFailure(
                        message:
                            "unicode byte-range mismatch "
                            + "capacity=\(capacityValue) "
                            + "chunk=\(chunkValue)"
                    )
                }

                guard scan.result.bytesExamined
                    == UInt64(
                        fixture.bytes.count
                    )
                else {
                    throw TestFailure(
                        message:
                            "unicode bytes examined mismatch "
                            + "capacity=\(capacityValue) "
                            + "chunk=\(chunkValue)"
                    )
                }

                guard scan.statistics.source.refilledByteCount
                    == UInt64(fixture.bytes.count)
                else {
                    throw TestFailure(
                        message:
                            "unicode backend offset mismatch"
                    )
                }

                guard scan.statistics.peakSourceBufferedByteCount
                    <= capacityValue
                else {
                    throw TestFailure(
                        message:
                            "Source exceeded configured "
                            + "buffer capacity"
                    )
                }

                for (
                    index,
                    selected
                ) in scan.result.lines.enumerated() {
                    let expectedBytes =
                        fixture.contentBytes[
                            index
                        ]

                    guard Array(
                        selected.text.utf8
                    ) == expectedBytes
                    else {
                        throw TestFailure(
                            message:
                                "valid UTF-8 did not "
                                + "round-trip for line "
                                + "\(selected.number)"
                        )
                    }
                }
            }
        }
    }

    static func testSelectionInvalidUTF8() throws {
        let rawLines: [[UInt8]] = [
            [
                0x66,
                0x6F,
                0x80,
                0x6F,
            ],
            [
                0xF0,
                0x28,
                0x8C,
                0x28,
            ],
            [
                0xE2,
                0x82,
            ],
            [
                0xC3,
            ],
        ]

        let fixture = makeRawVerificationFixture(
            rawLines: rawLines,
            endings: [
                [0x0A],
                [0x0D, 0x0A],
                [0x0A],
                [],
            ]
        )

        let expectedTexts = rawLines.map {
            String(
                decoding: $0,
                as: UTF8.self
            )
        }

        for capacityValue in 1...5 {
            for chunkValue in 1...3 {
                let backend = MemorySource(
                    bytes: fixture.bytes,
                    maximumChunkSize:
                        try PositiveByteCount(
                            chunkValue
                        )
                )

                let source = Source(
                    backend,
                    bufferCapacity:
                        try BufferCapacity(
                            capacityValue
                        )
                )

                let scan = try scanSourceSelection(
                    source: consume source,
                    ranges: [
                        1...rawLines.count,
                    ]
                )

                let actualTexts =
                    scan.result.lines.map(
                        \.text
                    )

                guard actualTexts
                    == expectedTexts
                else {
                    throw TestFailure(
                        message:
                            "invalid UTF-8 replacement "
                            + "semantics changed across "
                            + "fragmentation "
                            + "capacity=\(capacityValue) "
                            + "chunk=\(chunkValue)"
                    )
                }

                guard scan.result.byteRanges
                    == fixture.byteRanges
                else {
                    throw TestFailure(
                        message:
                            "invalid UTF-8 changed "
                            + "byte offsets"
                    )
                }

                guard scan.statistics.peakSourceBufferedByteCount
                    <= capacityValue
                else {
                    throw TestFailure(
                        message:
                            "invalid UTF-8 test "
                            + "exceeded Source capacity"
                    )
                }
            }
        }
    }

    static func testSelectionLongLineBounds() throws {
        let longLine = String(
            repeating:
                "🐕é€x👨‍👩‍👧‍👦",
            count: 4_096
        )

        let fixture = makeStringVerificationFixture(
            lines: [
                "prefix",
                longLine,
                "suffix🚀",
            ],
            endings: [
                [0x0A],
                [0x0D, 0x0A],
                [],
            ]
        )

        let expectedLongPayloadByteCount =
            longLine.utf8.count
        let expectedLongWorkingByteCount =
            expectedLongPayloadByteCount + 1

        for capacityValue in [
            1,
            2,
            3,
            7,
            64,
            4_096,
        ] {
            let backend = MemorySource(
                bytes: fixture.bytes,
                maximumChunkSize:
                    try PositiveByteCount(
                        max(
                            1,
                            min(
                                31,
                                capacityValue
                            )
                        )
                    )
            )

            let source = Source(
                backend,
                bufferCapacity:
                    try BufferCapacity(
                        capacityValue
                    )
            )

            let scan = try scanSourceSelection(
                source: consume source,
                ranges: [
                    2...2,
                ]
            )

            guard scan.result.lines
                == [
                    .init(
                        number: 2,
                        text: longLine
                    ),
                ]
            else {
                throw TestFailure(
                    message:
                        "long selected line changed "
                        + "at capacity "
                        + "\(capacityValue)"
                )
            }

            guard scan.result.byteRanges
                == [
                    fixture.byteRanges[1],
                ]
            else {
                throw TestFailure(
                    message:
                        "long-line byte range changed "
                        + "at capacity "
                        + "\(capacityValue)"
                )
            }

            guard scan.result
                .peakSelectedLineByteCount
                == expectedLongWorkingByteCount
            else {
                throw TestFailure(
                    message:
                        "long-line retained-byte "
                        + "measurement is incorrect"
                )
            }

            guard scan.statistics.peakSourceBufferedByteCount
                <= capacityValue
            else {
                throw TestFailure(
                    message:
                        "long-line scan exceeded "
                        + "configured Source capacity"
                )
            }

            guard scan.statistics.source.refilledByteCount
                <= UInt64(fixture.bytes.count)
            else {
                throw TestFailure(
                    message:
                        "long-line backend offset "
                        + "advanced beyond fixture"
                )
            }
        }
    }

    static func testSelectionVariableFragmentation() throws {
        let lines = (1...200).map {
            index in
            switch index % 7 {
            case 0:
                return "\(index)|🐕|€|é"

            case 1:
                return "\(index)|👨‍👩‍👧‍👦"

            case 2:
                return "\(index)|e\u{301}|🇳🇱"

            case 3:
                return "\(index)|ASCII"

            case 4:
                return "\(index)|🚀🌍🧪"

            case 5:
                return ""

            default:
                return "\(index)|শেষ|最後"
            }
        }

        let endings = lines.indices.map {
            index -> [UInt8] in
            if index == lines.indices.last {
                return []
            }

            return index.isMultiple(
                of: 3
            )
                ? [0x0D, 0x0A]
                : [0x0A]
        }

        let fixture =
            makeStringVerificationFixture(
                lines: lines,
                endings: endings
            )

        let ranges: [
            ClosedRange<Int>
        ] = [
            1...7,
            33...41,
            99...104,
            180...200,
        ]

        let expectedLines =
            expectedSelectedLines(
                fixture: fixture,
                ranges: ranges
            )
        let expectedRanges =
            expectedSelectedRanges(
                fixture: fixture,
                ranges: ranges
            )

        for seed in 1...24 {
            let backend =
                VariableFragmentSource(
                    bytes: fixture.bytes,
                    seed: UInt64(
                        seed
                    )
                )

            let capacityValue =
                1 + (seed % 17)

            let source = Source(
                backend,
                bufferCapacity:
                    try BufferCapacity(
                        capacityValue
                    )
            )

            let scan =
                try scanSourceSelection(
                    source: consume source,
                    ranges: ranges
                )

            guard scan.result.lines
                == expectedLines
            else {
                throw TestFailure(
                    message:
                        "variable fragmentation "
                        + "changed selected text "
                        + "seed=\(seed)"
                )
            }

            guard scan.result.byteRanges
                == expectedRanges
            else {
                throw TestFailure(
                    message:
                        "variable fragmentation "
                        + "changed byte offsets "
                        + "seed=\(seed)"
                )
            }

            guard scan.statistics.source.refilledByteCount
                == UInt64(fixture.bytes.count)
            else {
                throw TestFailure(
                    message:
                        "variable fragmentation "
                        + "lost/duplicated bytes "
                        + "seed=\(seed)"
                )
            }

            guard scan.statistics.peakSourceBufferedByteCount
                <= capacityValue
            else {
                throw TestFailure(
                    message:
                        "variable fragmentation "
                        + "exceeded Source capacity "
                        + "seed=\(seed)"
                )
            }
        }
    }

    static func testSourceConsumeBounds() throws {
        let backend = MemorySource(
            bytes: [
                1,
                2,
                3,
            ]
        )

        var source = Source(
            backend,
            bufferCapacity:
                try BufferCapacity(
                    2
                )
        )

        guard try source.prepare()
            == .bytes
        else {
            throw TestFailure(
                message:
                    "consume-bounds source "
                    + "did not prepare bytes"
            )
        }

        let before =
            source.withBytes {
                Array(
                    $0
                )
            }

        do {
            try source.consume(
                -1
            )

            throw TestFailure(
                message:
                    "negative Source.consume "
                    + "unexpectedly succeeded"
            )
        } catch StreamContractError
            .negative_consume(-1)
        {
        }

        guard source.withBytes({
            Array($0)
        }) == before
        else {
            throw TestFailure(
                message:
                    "failed negative consume "
                    + "mutated Source state"
            )
        }

        do {
            try source.consume(
                3
            )

            throw TestFailure(
                message:
                    "over-consume "
                    + "unexpectedly succeeded"
            )
        } catch StreamContractError
            .consume_exceeds_available(
                requested: 3,
                available: 2
            )
        {
        }

        guard source.withBytes({
            Array($0)
        }) == before
        else {
            throw TestFailure(
                message:
                    "failed over-consume "
                    + "mutated Source state"
            )
        }

        try source.consume(
            1
        )

        guard try source.requestMore()
            == .bytes
        else {
            throw TestFailure(
                message:
                    "Source could not refill "
                    + "after bounded consume"
            )
        }

        guard source.withReadableRegions({ first, second in
            Array(first) + Array(second)
        }) == [
            2,
            3,
        ]
        else {
            throw TestFailure(
                message:
                    "Source offset/cursor "
                    + "changed bytes after "
                    + "compact + refill"
            )
        }
    }
}

struct VerificationFixture {
    let bytes: [UInt8]
    let lines: [BenchmarkSelectedLine]
    let contentBytes: [[UInt8]]
    let byteRanges: [Range<UInt64>]
}

struct VariableFragmentSource:
    SourceBackend, ~Copyable
{
    let bytes: [UInt8]

    private(set) var offset: Int

    private var state: UInt64

    init(
        bytes: [UInt8],
        seed: UInt64
    ) {
        self.bytes = bytes
        self.offset = 0
        self.state = seed
            == 0
            ? 1
            : seed
    }

    mutating func refill(
        into output:
            UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        guard offset < bytes.count else {
            return .end
        }

        guard !output.isEmpty else {
            return .unavailable
        }

        state =
            state
            &* 6364136223846793005
            &+ 1442695040888963407

        let maximum = min(
            output.count,
            bytes.count - offset
        )

        let count =
            1
            + Int(
                state
                    % UInt64(
                        maximum
                    )
            )

        for index in 0..<count {
            output[index] =
                bytes[
                    offset + index
                ]
        }

        offset += count

        let progress =
            try PositiveByteCount(
                count
            )

        if offset == bytes.count {
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
    static func makeUnicodeVerificationFixture()
        -> VerificationFixture
    {
        makeStringVerificationFixture(
            lines: [
                "ascii",
                "é",
                "€",
                "🐕",
                "👨‍👩‍👧‍👦",
                "e\u{301}",
                "🇳🇱",
                "",
                "最後の行🚀",
            ],
            endings: [
                [0x0D, 0x0A],
                [0x0A],
                [0x0D, 0x0A],
                [0x0A],
                [0x0D, 0x0A],
                [0x0A],
                [0x0A],
                [0x0A],
                [],
            ]
        )
    }

    static func makeStringVerificationFixture(
        lines: [String],
        endings: [[UInt8]]
    ) -> VerificationFixture {
        makeRawVerificationFixture(
            rawLines: lines.map {
                Array(
                    $0.utf8
                )
            },
            endings: endings
        )
    }

    static func makeRawVerificationFixture(
        rawLines: [[UInt8]],
        endings: [[UInt8]]
    ) -> VerificationFixture {
        precondition(
            rawLines.count
                == endings.count
        )

        var bytes: [UInt8] = []
        var lines:
            [BenchmarkSelectedLine] = []
        var contentBytes:
            [[UInt8]] = []
        var byteRanges:
            [Range<UInt64>] = []

        for index in rawLines.indices {
            let lineNumber = index + 1
            let start = UInt64(
                bytes.count
            )

            let rawContent =
                rawLines[index]
            let ending =
                endings[index]

            bytes.append(
                contentsOf: rawContent
            )

            var semanticContent =
                rawContent
            var contentEnd = UInt64(
                bytes.count
            )

            if ending == [
                0x0D,
                0x0A,
            ] {
                // The CR belonging to CRLF is outside the payload. If rawContent itself
                // already ends in CR, that byte remains part of the logical line.
                bytes.append(
                    0x0D
                )
                bytes.append(
                    0x0A
                )
            } else {
                // With LF-only or EOF termination, a payload CR immediately before the
                // boundary is the CR that the text-selection layer trims.
                if semanticContent.last == 0x0D {
                    semanticContent.removeLast()
                    contentEnd -= 1
                }

                bytes.append(
                    contentsOf: ending
                )
            }

            byteRanges.append(
                start..<contentEnd
            )
            contentBytes.append(
                semanticContent
            )
            lines.append(
                .init(
                    number: lineNumber,
                    text: String(
                        decoding: semanticContent,
                        as: UTF8.self
                    )
                )
            )
        }

        return .init(
            bytes: bytes,
            lines: lines,
            contentBytes: contentBytes,
            byteRanges: byteRanges
        )
    }

    static func expectedSelectedLines(
        fixture: VerificationFixture,
        ranges: [ClosedRange<Int>]
    ) -> [BenchmarkSelectedLine] {
        let normalized = normalize(
            ranges
        )

        return fixture.lines.filter {
            line in
            normalized.contains {
                $0.contains(
                    line.number
                )
            }
        }
    }

    static func expectedSelectedRanges(
        fixture: VerificationFixture,
        ranges: [ClosedRange<Int>]
    ) -> [Range<UInt64>] {
        let normalized = normalize(
            ranges
        )

        return fixture.lines.enumerated()
            .compactMap {
                index,
                line in
                guard normalized.contains(
                    where: {
                        $0.contains(
                            line.number
                        )
                    }
                ) else {
                    return nil
                }

                return fixture.byteRanges[
                    index
                ]
            }
    }
}
