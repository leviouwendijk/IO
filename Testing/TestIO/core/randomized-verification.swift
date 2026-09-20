import IO

extension TestIO {
    /// Deterministic property-style verification over many byte layouts, UTF-8 sequences,
    /// selection sets, Source capacities, and backend fragmentation schedules.
    static func testSelectionRandomizedProperties() throws {
        for seed in 1...128 {
            var random = DeterministicRandom(
                state: UInt64(seed)
            )

            let lineCount = random.int(
                in: 1...80
            )

            var rawLines: [[UInt8]] = []
            rawLines.reserveCapacity(
                lineCount
            )

            var endings: [[UInt8]] = []
            endings.reserveCapacity(
                lineCount
            )

            for lineIndex in 0..<lineCount {
                rawLines.append(
                    randomVerificationLine(
                        random: &random
                    )
                )

                if lineIndex == lineCount - 1,
                   random.int(in: 0...1) == 0
                {
                    endings.append([])
                } else if random.int(in: 0...3) == 0 {
                    endings.append([
                        0x0D,
                        0x0A,
                    ])
                } else {
                    endings.append([
                        0x0A,
                    ])
                }
            }

            let fixture = makeRawVerificationFixture(
                rawLines: rawLines,
                endings: endings
            )

            let ranges = randomSelectionRanges(
                lineCount: lineCount,
                random: &random
            )

            let expectedLines = expectedSelectedLines(
                fixture: fixture,
                ranges: ranges
            )
            let expectedRanges = expectedSelectedRanges(
                fixture: fixture,
                ranges: ranges
            )

            let capacityValue = random.int(
                in: 1...128
            )

            let source = Source(
                VariableFragmentSource(
                    bytes: fixture.bytes,
                    seed: random.next()
                ),
                bufferCapacity: try BufferCapacity(
                    capacityValue
                )
            )

            let scan = try scanSourceSelection(
                source: consume source,
                ranges: ranges
            )

            try expectEqual(
                scan.result.lines,
                expectedLines,
                "randomized selected lines seed=\(seed)"
            )
            try expectEqual(
                scan.result.byteRanges,
                expectedRanges,
                "randomized byte ranges seed=\(seed)"
            )

            try expect(
                scan.statistics.peakSourceBufferedByteCount
                    <= capacityValue,
                "randomized Source exceeded capacity seed=\(seed)"
            )

            try expect(
                scan.statistics.source.refilledByteCount
                    <= UInt64(fixture.bytes.count),
                "randomized Source advanced beyond fixture seed=\(seed)"
            )

            try expect(
                scan.result.selectedByteCopyCount
                    >= scan.result.selectedPayloadBytes,
                "selected-byte copy accounting under-counted payload seed=\(seed)"
            )
        }
    }

    /// Repeated stop/resume drives must be observationally equivalent to one uninterrupted
    /// scan, even when stops occur in the middle of logical lines and UTF-8 scalars.
    static func testScannerRandomizedStopResume() throws {
        for seed in 1...64 {
            var random = DeterministicRandom(
                state: UInt64(seed) &* 0x9E3779B97F4A7C15
            )

            let lineCount = random.int(
                in: 1...96
            )

            var rawLines: [[UInt8]] = []
            var endings: [[UInt8]] = []

            for lineIndex in 0..<lineCount {
                rawLines.append(
                    randomVerificationLine(
                        random: &random
                    )
                )

                if lineIndex == lineCount - 1,
                   random.int(in: 0...2) == 0
                {
                    endings.append([])
                } else if random.int(in: 0...4) == 0 {
                    endings.append([
                        0x0D,
                        0x0A,
                    ])
                } else {
                    endings.append([
                        0x0A,
                    ])
                }
            }

            let fixture = makeRawVerificationFixture(
                rawLines: rawLines,
                endings: endings
            )

            let capacityValue = random.int(
                in: 1...64
            )

            var scanner = ByteLineScanner(
                source: Source(
                    VariableFragmentSource(
                        bytes: fixture.bytes,
                        seed: random.next()
                    ),
                    bufferCapacity: try BufferCapacity(
                        capacityValue
                    )
                )
            )

            var reconstructed: [UInt8] = []
            reconstructed.reserveCapacity(
                fixture.bytes.count
            )

            var ended = false
            var driveCount = 0

            while !ended {
                driveCount += 1

                guard driveCount
                    <= max(
                        32,
                        fixture.bytes.count * 4
                    )
                else {
                    throw TestFailure(
                        message:
                            "randomized scanner failed to converge seed=\(seed)"
                    )
                }

                let result = try scanner.scan {
                    fragment in
                    reconstructed.append(
                        contentsOf: fragment.bytes
                    )

                    if fragment.ending == .line_feed {
                        reconstructed.append(
                            0x0A
                        )
                    }

                    if random.int(in: 0...4) == 0 {
                        return .stop
                    }

                    return .continue
                }

                switch result {
                case .end:
                    ended = true

                case .stopped:
                    continue

                case .unavailable:
                    throw TestFailure(
                        message:
                            "memory-backed randomized scanner became unavailable seed=\(seed)"
                    )
                }
            }

            try expectEqual(
                reconstructed,
                fixture.bytes,
                "randomized scanner byte reconstruction seed=\(seed)"
            )

            try expectEqual(
                scanner.statistics.source.refilledByteCount,
                UInt64(fixture.bytes.count),
                "randomized scanner refilled-byte count seed=\(seed)"
            )

            try expect(
                scanner.statistics.peakSourceBufferedByteCount
                    <= capacityValue,
                "randomized scanner exceeded Source capacity seed=\(seed)"
            )
        }
    }

    private static func randomVerificationLine(
        random: inout DeterministicRandom
    ) -> [UInt8] {
        let tokens: [[UInt8]] = [
            [],
            Array("ASCII".utf8),
            Array("é".utf8),
            Array("€".utf8),
            Array("🐕".utf8),
            Array("👨‍👩‍👧‍👦".utf8),
            Array("e\u{301}".utf8),
            Array("🇳🇱".utf8),
            Array("最後".utf8),
            Array("শেষ".utf8),
            [0x80],
            [0xC3],
            [
                0xE2,
                0x82,
            ],
            [
                0xF0,
                0x28,
                0x8C,
                0x28,
            ],
            [0x0D],
        ]

        let tokenCount = random.int(
            in: 0...24
        )

        var bytes: [UInt8] = []

        for _ in 0..<tokenCount {
            bytes.append(
                contentsOf: tokens[
                    random.int(
                        in: 0...(tokens.count - 1)
                    )
                ]
            )
        }

        return bytes
    }

    private static func randomSelectionRanges(
        lineCount: Int,
        random: inout DeterministicRandom
    ) -> [ClosedRange<Int>] {
        var selected = Array(
            repeating: false,
            count: lineCount
        )

        for index in selected.indices {
            selected[index] =
                random.int(in: 0...3) == 0
        }

        if !selected.contains(true) {
            selected[
                random.int(
                    in: 0...(lineCount - 1)
                )
            ] = true
        }

        var ranges: [ClosedRange<Int>] = []
        var index = 0

        while index < selected.count {
            guard selected[index] else {
                index += 1
                continue
            }

            let start = index
            var end = index

            while end + 1 < selected.count,
                  selected[end + 1]
            {
                end += 1
            }

            ranges.append(
                (start + 1)...(end + 1)
            )
            index = end + 1
        }

        return ranges
    }
}

struct DeterministicRandom {
    private(set) var state: UInt64

    mutating func next() -> UInt64 {
        var value = state

        if value == 0 {
            value = 0xD1B54A32D192ED03
        }

        value ^= value << 13
        value ^= value >> 7
        value ^= value << 17

        state = value
        return value
    }

    mutating func int(
        in range: ClosedRange<Int>
    ) -> Int {
        let width = UInt64(
            range.upperBound
                - range.lowerBound
                + 1
        )

        return range.lowerBound
            + Int(next() % width)
    }
}
