import Dispatch
import IO
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private enum ScannerHybridKernel: CaseIterable, Hashable {
    case memchr
    case simd16
    case simd32
    case simd64
    case hybrid32_64
    case hybrid32_128
    case adaptive16_64_2
    case adaptive16_128_2
    case adaptive32_128_2
    case adaptive32_128_4

    var label: String {
        switch self {
        case .memchr:
            "memchr"
        case .simd16:
            "SIMD16"
        case .simd32:
            "SIMD32"
        case .simd64:
            "SIMD64"
        case .hybrid32_64:
            "hybrid32@64"
        case .hybrid32_128:
            "hybrid32@128"
        case .adaptive16_64_2:
            "adaptive16 2/64"
        case .adaptive16_128_2:
            "adaptive16 2/128"
        case .adaptive32_128_2:
            "adaptive32 2/128"
        case .adaptive32_128_4:
            "adaptive32 4/128"
        }
    }
}

private struct ScannerHybridPositionResult: Equatable {
    let lineFeedCount: UInt64
    let checksum: UInt64
}

private struct ScannerHybridSemanticResult: Equatable {
    let byteCount: UInt64
    let lineFeedCount: UInt64
    let fragmentCount: UInt64
    let checksum: UInt64
}

private struct ScannerHybridTiming {
    let result: ScannerHybridPositionResult
    let medianNanoseconds: UInt64
    let minimumNanoseconds: UInt64
    let maximumNanoseconds: UInt64
}

private struct ScannerHybridSemanticTiming {
    let result: ScannerHybridSemanticResult
    let medianNanoseconds: UInt64
    let minimumNanoseconds: UInt64
    let maximumNanoseconds: UInt64
}

private struct ScannerHybridLocalSemanticState {
    var lineNumber: UInt64
    var lineStartOffset: UInt64
    var absoluteOffset: UInt64
    var currentLineHasBytes: Bool
    var fragments: UInt64
    var completedLines: UInt64
    var checksum: UInt64
    var fragmentStart: Int
}

private struct ScannerHybridCursor {
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
                preconditionFailure("scanner hybrid pattern unexpectedly empty")
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

private struct ScannerHybridBackend: SourceBackend, ~Copyable {
    private var cursor: ScannerHybridCursor
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
    static func testScannerHybridKernelEquivalence() throws {
        let kernels = ScannerHybridKernel.allCases
        let spans = [
            1, 7, 15, 16, 17,
            31, 32, 33,
            63, 64, 65,
            127, 128, 129,
            257, 4096,
        ]
        let strides = [
            1, 2, 7, 15, 16, 17,
            31, 32, 33,
            63, 64, 65,
            127, 1021,
        ]

        for span in spans {
            for stride in strides {
                let pattern = scannerHybridPattern(
                    byteCount: span,
                    lineStride: stride
                )
                let reference = pattern.withUnsafeBytes {
                    scannerHybridPositionResult(
                        bytes: $0,
                        kernel: .memchr,
                        baseOffset: 0
                    )
                }

                for kernel in kernels {
                    let value = pattern.withUnsafeBytes {
                        scannerHybridPositionResult(
                            bytes: $0,
                            kernel: kernel,
                            baseOffset: 0
                        )
                    }

                    try expectEqual(
                        value,
                        reference,
                        "scanner hybrid \(kernel.label) span=\(span) stride=\(stride)"
                    )
                }
            }
        }

        let semanticPattern = scannerHybridPattern(
            byteCount: 64 * 1024,
            lineStride: 31
        )
        let totalByteCount = semanticPattern.count * 3

        for capacityValue in [17, 64, 257, 4096, 64 * 1024] {
            let capacity = try BufferCapacity(
                capacityValue
            )
            let reference = try scannerHybridSemanticScan(
                pattern: semanticPattern,
                totalByteCount: totalByteCount,
                capacity: capacity,
                kernel: .memchr
            )

            for kernel in kernels {
                let value = try scannerHybridSemanticScan(
                    pattern: semanticPattern,
                    totalByteCount: totalByteCount,
                    capacity: capacity,
                    kernel: kernel
                )

                try expectEqual(
                    value,
                    reference,
                    "scanner fused \(kernel.label) capacity=\(capacityValue)"
                )
            }
        }
    }

    static func runScannerHybridKernelBenchmarks(
        heavy: Bool
    ) throws {
        let logicalByteCount = heavy
            ? 64 * 1024 * 1024
            : 32 * 1024 * 1024
        let rounds = heavy ? 9 : 5
        let kernels = ScannerHybridKernel.allCases

        print("ByteLineScanner hybrid-kernel tuning · in-memory")
        print(
            "  logical work/sample: "
            + formatBytes(UInt64(logicalByteCount))
            + " · \(rounds) interleaved rounds · no benchmark file"
        )
        print(
            "  SIMD kernels compare many bytes at once, extract every LF from the match mask,"
        )
        print(
            "  and the fused scan consumes those positions directly into line/offset/fragment state."
        )
        print("")

        print("span-size crossover · line stride ~4 KiB")
        let spanSizes = [
            64,
            128,
            256,
            1024,
            4096,
            16 * 1024,
            64 * 1024,
            256 * 1024,
        ]

        for (scenarioIndex, spanSize) in spanSizes.enumerated() {
            let pattern = scannerHybridPattern(
                byteCount: spanSize,
                lineStride: 4093
            )
            let timings = try scannerHybridTimePositionKernels(
                kernels: kernels,
                pattern: pattern,
                logicalByteCount: logicalByteCount,
                rounds: rounds,
                scenarioIndex: scenarioIndex
            )

            try scannerHybridPrintPositionScenario(
                label: "  span " + formatBytes(UInt64(spanSize)),
                timings: timings,
                kernels: kernels
            )
        }

        print("")
        print("LF-density crossover · span 64 KiB")
        let lineStrides = [
            8,
            31,
            127,
            1021,
            4093,
            16_381,
            65_521,
        ]

        for (scenarioIndex, stride) in lineStrides.enumerated() {
            let pattern = scannerHybridPattern(
                byteCount: 64 * 1024,
                lineStride: stride
            )
            let timings = try scannerHybridTimePositionKernels(
                kernels: kernels,
                pattern: pattern,
                logicalByteCount: logicalByteCount,
                rounds: rounds,
                scenarioIndex: spanSizes.count + scenarioIndex
            )

            try scannerHybridPrintPositionScenario(
                label: "  LF every ~" + formatBytes(UInt64(stride)),
                timings: timings,
                kernels: kernels
            )
        }

        print("")
        print("fused semantic scanner · Source buffer 64 KiB")
        let semanticProfiles: [(String, Int)] = [
            ("short lines (~32 B)", 31),
            ("medium lines (~4 KiB)", 4093),
            ("sparse LF (~64 KiB)", 65_521),
        ]
        let semanticCapacity = try BufferCapacity(
            64 * 1024
        )

        for (profileIndex, profile) in semanticProfiles.enumerated() {
            let pattern = scannerHybridPattern(
                byteCount: 64 * 1024,
                lineStride: profile.1
            )
            let timings = try scannerHybridTimeSemanticKernels(
                kernels: kernels,
                pattern: pattern,
                totalByteCount: logicalByteCount,
                capacity: semanticCapacity,
                rounds: rounds,
                scenarioIndex: spanSizes.count + lineStrides.count + profileIndex
            )

            try scannerHybridPrintSemanticScenario(
                label: "  " + profile.0,
                timings: timings,
                kernels: kernels
            )
        }

        print("")
        print("tuning notes:")
        print("  memchr is the production control; this pass does not replace it.")
        print("  SIMD16/32/64 use one vector comparison per block and walk every set match bit.")
        print("  span hybrids use memchr below their crossover; adaptive variants probe 64/128 B and choose by observed LF density.")
        print("  prefer a kernel only if it wins across the fused semantic rows, not merely one search-only cell.")
        print("  the span and density sweeps reveal where a crossover should live; do not hard-code a threshold from theory alone.")
        print("")
    }
}

private extension TestIO {
    static let scannerHybridHighBits: UInt64 = 0x8080_8080_8080_8080

    @inline(__always)
    static func scannerHybridMix(
        _ checksum: inout UInt64,
        _ value: UInt64
    ) {
        checksum ^= value &+ 0x9E37_79B9_7F4A_7C15
        checksum = (checksum << 13) | (checksum >> 51)
        checksum &*= 0xBF58_476D_1CE4_E5B9
    }

    static func scannerHybridPattern(
        byteCount: Int,
        lineStride: Int
    ) -> [UInt8] {
        precondition(byteCount > 0)
        precondition(lineStride > 0)

        var bytes = Array(
            repeating: UInt8(ascii: "a"),
            count: byteCount
        )

        for index in bytes.indices {
            bytes[index] = UInt8(
                97 + (index % 26)
            )

            if (index + 1) % lineStride == 0 {
                bytes[index] = 0x0A
            }
        }

        bytes[bytes.count - 1] = 0x0A
        return bytes
    }

    static func scannerHybridPositionResult(
        bytes: UnsafeRawBufferPointer,
        kernel: ScannerHybridKernel,
        baseOffset: UInt64
    ) -> ScannerHybridPositionResult {
        var lineFeeds: UInt64 = 0
        var checksum: UInt64 = 0

        scannerHybridVisit(
            bytes: bytes,
            kernel: kernel
        ) { index in
            lineFeeds += 1
            scannerHybridMix(
                &checksum,
                baseOffset + UInt64(index)
            )
        }

        return .init(
            lineFeedCount: lineFeeds,
            checksum: checksum
        )
    }

    @inline(__always)
    static func scannerHybridVisit(
        bytes: UnsafeRawBufferPointer,
        kernel: ScannerHybridKernel,
        _ body: (Int) -> Void
    ) {
        switch kernel {
        case .memchr:
            scannerHybridVisitMemchr(
                bytes: bytes,
                from: 0,
                body
            )

        case .simd16:
            scannerHybridVisitSIMD16(
                bytes: bytes,
                from: 0,
                useMemchrTail: false,
                body
            )

        case .simd32:
            scannerHybridVisitSIMD32(
                bytes: bytes,
                from: 0,
                useMemchrTail: false,
                body
            )

        case .simd64:
            scannerHybridVisitSIMD64(
                bytes: bytes,
                from: 0,
                useMemchrTail: false,
                body
            )

        case .hybrid32_64:
            if bytes.count < 64 {
                scannerHybridVisitMemchr(
                    bytes: bytes,
                    from: 0,
                    body
                )
            } else {
                scannerHybridVisitSIMD32(
                    bytes: bytes,
                    from: 0,
                    useMemchrTail: true,
                    body
                )
            }

        case .hybrid32_128:
            if bytes.count < 128 {
                scannerHybridVisitMemchr(
                    bytes: bytes,
                    from: 0,
                    body
                )
            } else {
                scannerHybridVisitSIMD32(
                    bytes: bytes,
                    from: 0,
                    useMemchrTail: true,
                    body
                )
            }

        case .adaptive16_64_2:
            scannerHybridVisitAdaptive16(
                bytes: bytes,
                probeByteCount: 64,
                minimumMatches: 2,
                body
            )

        case .adaptive16_128_2:
            scannerHybridVisitAdaptive16(
                bytes: bytes,
                probeByteCount: 128,
                minimumMatches: 2,
                body
            )

        case .adaptive32_128_2:
            scannerHybridVisitAdaptive32(
                bytes: bytes,
                probeByteCount: 128,
                minimumMatches: 2,
                body
            )

        case .adaptive32_128_4:
            scannerHybridVisitAdaptive32(
                bytes: bytes,
                probeByteCount: 128,
                minimumMatches: 4,
                body
            )
        }
    }

    @inline(__always)
    static func scannerHybridVisitAdaptive16(
        bytes: UnsafeRawBufferPointer,
        probeByteCount: Int,
        minimumMatches: Int,
        _ body: (Int) -> Void
    ) {
        guard bytes.count >= probeByteCount,
              let base = bytes.baseAddress
        else {
            scannerHybridVisitMemchr(
                bytes: bytes,
                from: 0,
                body
            )
            return
        }

        let needle = SIMD16<UInt8>(
            repeating: 0x0A
        )
        var offset = 0
        var probeMatches = 0

        while offset + 16 <= probeByteCount {
            let vector = base
                .advanced(by: offset)
                .loadUnaligned(
                    as: SIMD16<UInt8>.self
                )
            let words = unsafeBitCast(
                vector .== needle,
                to: SIMD2<UInt64>.self
            )

            for lane in 0..<2 {
                var bits =
                    UInt64(littleEndian: words[lane])
                    & scannerHybridHighBits

                probeMatches += bits.nonzeroBitCount

                while bits != 0 {
                    let byteOffset = bits.trailingZeroBitCount >> 3
                    body(
                        offset + lane * 8 + byteOffset
                    )
                    bits &= bits &- 1
                }
            }

            offset += 16
        }

        if probeMatches >= minimumMatches {
            let remaining = UnsafeRawBufferPointer(
                start: base.advanced(by: offset),
                count: bytes.count - offset
            )

            scannerHybridVisitSIMD16(
                bytes: remaining,
                from: 0,
                useMemchrTail: true
            ) { index in
                body(
                    offset + index
                )
            }
        } else {
            scannerHybridVisitMemchr(
                bytes: bytes,
                from: offset,
                body
            )
        }
    }

    @inline(__always)
    static func scannerHybridVisitAdaptive32(
        bytes: UnsafeRawBufferPointer,
        probeByteCount: Int,
        minimumMatches: Int,
        _ body: (Int) -> Void
    ) {
        guard bytes.count >= probeByteCount,
              let base = bytes.baseAddress
        else {
            scannerHybridVisitMemchr(
                bytes: bytes,
                from: 0,
                body
            )
            return
        }

        let needle = SIMD32<UInt8>(
            repeating: 0x0A
        )
        var offset = 0
        var probeMatches = 0

        while offset + 32 <= probeByteCount {
            let vector = base
                .advanced(by: offset)
                .loadUnaligned(
                    as: SIMD32<UInt8>.self
                )
            let mask = vector .== needle
            let words = unsafeBitCast(
                mask,
                to: SIMD4<UInt64>.self
            )

            for lane in 0..<4 {
                var bits =
                    UInt64(littleEndian: words[lane])
                    & scannerHybridHighBits

                probeMatches += bits.nonzeroBitCount

                while bits != 0 {
                    let byteOffset = bits.trailingZeroBitCount >> 3
                    body(
                        offset + lane * 8 + byteOffset
                    )
                    bits &= bits &- 1
                }
            }

            offset += 32
        }

        if probeMatches >= minimumMatches {
            let remaining = UnsafeRawBufferPointer(
                start: base.advanced(by: offset),
                count: bytes.count - offset
            )

            scannerHybridVisitSIMD32(
                bytes: remaining,
                from: 0,
                useMemchrTail: true
            ) { index in
                body(
                    offset + index
                )
            }
        } else {
            scannerHybridVisitMemchr(
                bytes: bytes,
                from: offset,
                body
            )
        }
    }

    @inline(__always)
    static func scannerHybridVisitMaskWord(
        _ rawWord: UInt64,
        baseOffset: Int,
        _ body: (Int) -> Void
    ) {
        var mask =
            UInt64(littleEndian: rawWord)
            & scannerHybridHighBits

        while mask != 0 {
            let byteOffset = mask.trailingZeroBitCount >> 3
            body(
                baseOffset + byteOffset
            )
            mask &= mask &- 1
        }
    }

    @inline(__always)
    static func scannerHybridVisitSIMD16(
        bytes: UnsafeRawBufferPointer,
        from start: Int,
        useMemchrTail: Bool,
        _ body: (Int) -> Void
    ) {
        guard let base = bytes.baseAddress else {
            return
        }

        let needle = SIMD16<UInt8>(
            repeating: 0x0A
        )
        var offset = start

        while offset + 16 <= bytes.count {
            let vector = base
                .advanced(by: offset)
                .loadUnaligned(
                    as: SIMD16<UInt8>.self
                )
            let mask = vector .== needle
            let words = unsafeBitCast(
                mask,
                to: SIMD2<UInt64>.self
            )

            if words[0] != 0 {
                scannerHybridVisitMaskWord(
                    words[0],
                    baseOffset: offset,
                    body
                )
            }

            if words[1] != 0 {
                scannerHybridVisitMaskWord(
                    words[1],
                    baseOffset: offset + 8,
                    body
                )
            }

            offset += 16
        }

        scannerHybridVisitTail(
            bytes: bytes,
            from: offset,
            useMemchr: useMemchrTail,
            body
        )
    }

    @inline(__always)
    static func scannerHybridVisitSIMD32(
        bytes: UnsafeRawBufferPointer,
        from start: Int,
        useMemchrTail: Bool,
        _ body: (Int) -> Void
    ) {
        guard let base = bytes.baseAddress else {
            return
        }

        let needle = SIMD32<UInt8>(
            repeating: 0x0A
        )
        var offset = start

        while offset + 32 <= bytes.count {
            let vector = base
                .advanced(by: offset)
                .loadUnaligned(
                    as: SIMD32<UInt8>.self
                )
            let mask = vector .== needle
            let words = unsafeBitCast(
                mask,
                to: SIMD4<UInt64>.self
            )

            if words[0] != 0 {
                scannerHybridVisitMaskWord(
                    words[0],
                    baseOffset: offset,
                    body
                )
            }
            if words[1] != 0 {
                scannerHybridVisitMaskWord(
                    words[1],
                    baseOffset: offset + 8,
                    body
                )
            }
            if words[2] != 0 {
                scannerHybridVisitMaskWord(
                    words[2],
                    baseOffset: offset + 16,
                    body
                )
            }
            if words[3] != 0 {
                scannerHybridVisitMaskWord(
                    words[3],
                    baseOffset: offset + 24,
                    body
                )
            }

            offset += 32
        }

        scannerHybridVisitTail(
            bytes: bytes,
            from: offset,
            useMemchr: useMemchrTail,
            body
        )
    }

    @inline(__always)
    static func scannerHybridVisitSIMD64(
        bytes: UnsafeRawBufferPointer,
        from start: Int,
        useMemchrTail: Bool,
        _ body: (Int) -> Void
    ) {
        guard let base = bytes.baseAddress else {
            return
        }

        let needle = SIMD64<UInt8>(
            repeating: 0x0A
        )
        var offset = start

        while offset + 64 <= bytes.count {
            let vector = base
                .advanced(by: offset)
                .loadUnaligned(
                    as: SIMD64<UInt8>.self
                )
            let mask = vector .== needle
            let words = unsafeBitCast(
                mask,
                to: SIMD8<UInt64>.self
            )

            if words[0] != 0 {
                scannerHybridVisitMaskWord(
                    words[0],
                    baseOffset: offset,
                    body
                )
            }
            if words[1] != 0 {
                scannerHybridVisitMaskWord(
                    words[1],
                    baseOffset: offset + 8,
                    body
                )
            }
            if words[2] != 0 {
                scannerHybridVisitMaskWord(
                    words[2],
                    baseOffset: offset + 16,
                    body
                )
            }
            if words[3] != 0 {
                scannerHybridVisitMaskWord(
                    words[3],
                    baseOffset: offset + 24,
                    body
                )
            }
            if words[4] != 0 {
                scannerHybridVisitMaskWord(
                    words[4],
                    baseOffset: offset + 32,
                    body
                )
            }
            if words[5] != 0 {
                scannerHybridVisitMaskWord(
                    words[5],
                    baseOffset: offset + 40,
                    body
                )
            }
            if words[6] != 0 {
                scannerHybridVisitMaskWord(
                    words[6],
                    baseOffset: offset + 48,
                    body
                )
            }
            if words[7] != 0 {
                scannerHybridVisitMaskWord(
                    words[7],
                    baseOffset: offset + 56,
                    body
                )
            }

            offset += 64
        }

        scannerHybridVisitTail(
            bytes: bytes,
            from: offset,
            useMemchr: useMemchrTail,
            body
        )
    }

    @inline(__always)
    static func scannerHybridVisitTail(
        bytes: UnsafeRawBufferPointer,
        from start: Int,
        useMemchr: Bool,
        _ body: (Int) -> Void
    ) {
        guard start < bytes.count else {
            return
        }

        if useMemchr {
            scannerHybridVisitMemchr(
                bytes: bytes,
                from: start,
                body
            )
            return
        }

        var index = start

        while index < bytes.count {
            if bytes[index] == 0x0A {
                body(
                    index
                )
            }

            index += 1
        }
    }

    @inline(__always)
    static func scannerHybridVisitMemchr(
        bytes: UnsafeRawBufferPointer,
        from start: Int,
        _ body: (Int) -> Void
    ) {
        guard start < bytes.count,
              let base = bytes.baseAddress
        else {
            return
        }

        var offset = start

        while offset < bytes.count {
            let searchBase = base.advanced(
                by: offset
            )
            let searchCount = bytes.count - offset

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
                return
            }

            let index = base.distance(
                to: UnsafeRawPointer(found)
            )
            body(
                index
            )
            offset = index + 1
        }
    }

    static func scannerHybridSemanticScan(
        pattern: [UInt8],
        totalByteCount: Int,
        capacity: BufferCapacity,
        kernel: ScannerHybridKernel
    ) throws -> ScannerHybridSemanticResult {
        var source = Source(
            ScannerHybridBackend(
                pattern: pattern,
                totalByteCount: totalByteCount,
                maximumChunkSize: capacity.value
            ),
            bufferCapacity: capacity
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
                var fragmentStart = 0

                source.withBytes { readable in
                    var state = ScannerHybridLocalSemanticState(
                        lineNumber: localLineNumber,
                        lineStartOffset: localLineStartOffset,
                        absoluteOffset: localAbsoluteOffset,
                        currentLineHasBytes: localCurrentLineHasBytes,
                        fragments: localFragments,
                        completedLines: localCompletedLines,
                        checksum: localChecksum,
                        fragmentStart: fragmentStart
                    )

                    scannerHybridSemanticVisit(
                        bytes: readable,
                        kernel: kernel,
                        state: &state
                    )

                    if state.fragmentStart < readable.count {
                        let count = readable.count - state.fragmentStart
                        let fragmentStartOffset = state.absoluteOffset
                        let fragmentEndOffset =
                            fragmentStartOffset
                            + UInt64(count)

                        state.fragments += 1

                        scannerHybridObserveSemantic(
                            checksum: &state.checksum,
                            lineNumber: state.lineNumber,
                            lineStartOffset: state.lineStartOffset,
                            fragmentStartOffset: fragmentStartOffset,
                            fragmentEndOffset: fragmentEndOffset,
                            byteCount: count,
                            ending: .none
                        )

                        state.absoluteOffset += UInt64(count)
                        state.currentLineHasBytes = true
                    }

                    localLineNumber = state.lineNumber
                    localLineStartOffset = state.lineStartOffset
                    localAbsoluteOffset = state.absoluteOffset
                    localCurrentLineHasBytes = state.currentLineHasBytes
                    localFragments = state.fragments
                    localCompletedLines = state.completedLines
                    localChecksum = state.checksum
                    fragmentStart = state.fragmentStart
                }

                try source.consume(
                    readableCount
                )

                bytesExamined += UInt64(readableCount)
                lineNumber = localLineNumber
                lineStartOffset = localLineStartOffset
                absoluteOffset = localAbsoluteOffset
                currentLineHasBytes = localCurrentLineHasBytes
                fragments = localFragments
                completedLines = localCompletedLines
                checksum = localChecksum

            case .end:
                if currentLineHasBytes {
                    fragments += 1
                    completedLines += 1

                    scannerHybridObserveSemantic(
                        checksum: &checksum,
                        lineNumber: lineNumber,
                        lineStartOffset: lineStartOffset,
                        fragmentStartOffset: absoluteOffset,
                        fragmentEndOffset: absoluteOffset,
                        byteCount: 0,
                        ending: .end
                    )
                }

                return .init(
                    byteCount: bytesExamined,
                    lineFeedCount: completedLines,
                    fragmentCount: fragments,
                    checksum: checksum
                )

            case .unavailable:
                throw TestFailure(
                    message: "scanner hybrid Source became unavailable"
                )

            case .buffer_full:
                throw TestFailure(
                    message: "scanner hybrid Source unexpectedly buffer-full"
                )
            }
        }
    }

    @inline(__always)
    static func scannerHybridSemanticVisit(
        bytes: UnsafeRawBufferPointer,
        kernel: ScannerHybridKernel,
        state: inout ScannerHybridLocalSemanticState
    ) {
        switch kernel {
        case .memchr:
            scannerHybridSemanticVisitMemchr(
                bytes: bytes,
                from: 0,
                state: &state
            )

        case .simd16:
            scannerHybridSemanticVisitSIMD16(
                bytes: bytes,
                from: 0,
                useMemchrTail: false,
                state: &state
            )

        case .simd32:
            scannerHybridSemanticVisitSIMD32(
                bytes: bytes,
                from: 0,
                useMemchrTail: false,
                state: &state
            )

        case .simd64:
            scannerHybridSemanticVisitSIMD64(
                bytes: bytes,
                from: 0,
                useMemchrTail: false,
                state: &state
            )

        case .hybrid32_64:
            if bytes.count < 64 {
                scannerHybridSemanticVisitMemchr(
                    bytes: bytes,
                    from: 0,
                    state: &state
                )
            } else {
                scannerHybridSemanticVisitSIMD32(
                    bytes: bytes,
                    from: 0,
                    useMemchrTail: true,
                    state: &state
                )
            }

        case .hybrid32_128:
            if bytes.count < 128 {
                scannerHybridSemanticVisitMemchr(
                    bytes: bytes,
                    from: 0,
                    state: &state
                )
            } else {
                scannerHybridSemanticVisitSIMD32(
                    bytes: bytes,
                    from: 0,
                    useMemchrTail: true,
                    state: &state
                )
            }

        case .adaptive16_64_2:
            scannerHybridSemanticVisitAdaptive16(
                bytes: bytes,
                probeByteCount: 64,
                minimumMatches: 2,
                state: &state
            )

        case .adaptive16_128_2:
            scannerHybridSemanticVisitAdaptive16(
                bytes: bytes,
                probeByteCount: 128,
                minimumMatches: 2,
                state: &state
            )

        case .adaptive32_128_2:
            scannerHybridSemanticVisitAdaptive32(
                bytes: bytes,
                probeByteCount: 128,
                minimumMatches: 2,
                state: &state
            )

        case .adaptive32_128_4:
            scannerHybridSemanticVisitAdaptive32(
                bytes: bytes,
                probeByteCount: 128,
                minimumMatches: 4,
                state: &state
            )
        }
    }

    @inline(__always)
    static func scannerHybridSemanticConsumeMatch(
        _ index: Int,
        state: inout ScannerHybridLocalSemanticState
    ) {
        let count = index - state.fragmentStart
        let fragmentStartOffset = state.absoluteOffset
        let fragmentEndOffset =
            fragmentStartOffset
            + UInt64(count)

        state.fragments += 1
        state.completedLines += 1

        scannerHybridObserveSemantic(
            checksum: &state.checksum,
            lineNumber: state.lineNumber,
            lineStartOffset: state.lineStartOffset,
            fragmentStartOffset: fragmentStartOffset,
            fragmentEndOffset: fragmentEndOffset,
            byteCount: count,
            ending: .line_feed
        )

        let consumedCount = count + 1
        state.absoluteOffset += UInt64(consumedCount)
        state.lineNumber += 1
        state.lineStartOffset = state.absoluteOffset
        state.currentLineHasBytes = false
        state.fragmentStart = index + 1
    }

    @inline(__always)
    static func scannerHybridSemanticConsumeMaskWord(
        _ rawWord: UInt64,
        baseOffset: Int,
        state: inout ScannerHybridLocalSemanticState
    ) {
        var mask =
            UInt64(littleEndian: rawWord)
            & scannerHybridHighBits

        while mask != 0 {
            let byteOffset = mask.trailingZeroBitCount >> 3
            scannerHybridSemanticConsumeMatch(
                baseOffset + byteOffset,
                state: &state
            )
            mask &= mask &- 1
        }
    }

    @inline(__always)
    static func scannerHybridSemanticVisitSIMD16(
        bytes: UnsafeRawBufferPointer,
        from start: Int,
        useMemchrTail: Bool,
        state: inout ScannerHybridLocalSemanticState
    ) {
        guard let base = bytes.baseAddress else {
            return
        }

        let needle = SIMD16<UInt8>(
            repeating: 0x0A
        )
        var offset = start

        while offset + 16 <= bytes.count {
            let vector = base
                .advanced(by: offset)
                .loadUnaligned(
                    as: SIMD16<UInt8>.self
                )
            let words = unsafeBitCast(
                vector .== needle,
                to: SIMD2<UInt64>.self
            )

            if words[0] != 0 {
                scannerHybridSemanticConsumeMaskWord(
                    words[0],
                    baseOffset: offset,
                    state: &state
                )
            }
            if words[1] != 0 {
                scannerHybridSemanticConsumeMaskWord(
                    words[1],
                    baseOffset: offset + 8,
                    state: &state
                )
            }

            offset += 16
        }

        scannerHybridSemanticVisitTail(
            bytes: bytes,
            from: offset,
            useMemchr: useMemchrTail,
            state: &state
        )
    }

    @inline(__always)
    static func scannerHybridSemanticVisitSIMD32(
        bytes: UnsafeRawBufferPointer,
        from start: Int,
        useMemchrTail: Bool,
        state: inout ScannerHybridLocalSemanticState
    ) {
        guard let base = bytes.baseAddress else {
            return
        }

        let needle = SIMD32<UInt8>(
            repeating: 0x0A
        )
        var offset = start

        while offset + 32 <= bytes.count {
            let vector = base
                .advanced(by: offset)
                .loadUnaligned(
                    as: SIMD32<UInt8>.self
                )
            let words = unsafeBitCast(
                vector .== needle,
                to: SIMD4<UInt64>.self
            )

            if words[0] != 0 {
                scannerHybridSemanticConsumeMaskWord(
                    words[0],
                    baseOffset: offset,
                    state: &state
                )
            }
            if words[1] != 0 {
                scannerHybridSemanticConsumeMaskWord(
                    words[1],
                    baseOffset: offset + 8,
                    state: &state
                )
            }
            if words[2] != 0 {
                scannerHybridSemanticConsumeMaskWord(
                    words[2],
                    baseOffset: offset + 16,
                    state: &state
                )
            }
            if words[3] != 0 {
                scannerHybridSemanticConsumeMaskWord(
                    words[3],
                    baseOffset: offset + 24,
                    state: &state
                )
            }

            offset += 32
        }

        scannerHybridSemanticVisitTail(
            bytes: bytes,
            from: offset,
            useMemchr: useMemchrTail,
            state: &state
        )
    }

    @inline(__always)
    static func scannerHybridSemanticVisitSIMD64(
        bytes: UnsafeRawBufferPointer,
        from start: Int,
        useMemchrTail: Bool,
        state: inout ScannerHybridLocalSemanticState
    ) {
        guard let base = bytes.baseAddress else {
            return
        }

        let needle = SIMD64<UInt8>(
            repeating: 0x0A
        )
        var offset = start

        while offset + 64 <= bytes.count {
            let vector = base
                .advanced(by: offset)
                .loadUnaligned(
                    as: SIMD64<UInt8>.self
                )
            let words = unsafeBitCast(
                vector .== needle,
                to: SIMD8<UInt64>.self
            )

            if words[0] != 0 {
                scannerHybridSemanticConsumeMaskWord(
                    words[0],
                    baseOffset: offset,
                    state: &state
                )
            }
            if words[1] != 0 {
                scannerHybridSemanticConsumeMaskWord(
                    words[1],
                    baseOffset: offset + 8,
                    state: &state
                )
            }
            if words[2] != 0 {
                scannerHybridSemanticConsumeMaskWord(
                    words[2],
                    baseOffset: offset + 16,
                    state: &state
                )
            }
            if words[3] != 0 {
                scannerHybridSemanticConsumeMaskWord(
                    words[3],
                    baseOffset: offset + 24,
                    state: &state
                )
            }
            if words[4] != 0 {
                scannerHybridSemanticConsumeMaskWord(
                    words[4],
                    baseOffset: offset + 32,
                    state: &state
                )
            }
            if words[5] != 0 {
                scannerHybridSemanticConsumeMaskWord(
                    words[5],
                    baseOffset: offset + 40,
                    state: &state
                )
            }
            if words[6] != 0 {
                scannerHybridSemanticConsumeMaskWord(
                    words[6],
                    baseOffset: offset + 48,
                    state: &state
                )
            }
            if words[7] != 0 {
                scannerHybridSemanticConsumeMaskWord(
                    words[7],
                    baseOffset: offset + 56,
                    state: &state
                )
            }

            offset += 64
        }

        scannerHybridSemanticVisitTail(
            bytes: bytes,
            from: offset,
            useMemchr: useMemchrTail,
            state: &state
        )
    }

    @inline(__always)
    static func scannerHybridSemanticVisitAdaptive16(
        bytes: UnsafeRawBufferPointer,
        probeByteCount: Int,
        minimumMatches: Int,
        state: inout ScannerHybridLocalSemanticState
    ) {
        guard bytes.count >= probeByteCount,
              let base = bytes.baseAddress
        else {
            scannerHybridSemanticVisitMemchr(
                bytes: bytes,
                from: 0,
                state: &state
            )
            return
        }

        let needle = SIMD16<UInt8>(
            repeating: 0x0A
        )
        var offset = 0
        var probeMatches = 0

        while offset + 16 <= probeByteCount {
            let vector = base
                .advanced(by: offset)
                .loadUnaligned(
                    as: SIMD16<UInt8>.self
                )
            let words = unsafeBitCast(
                vector .== needle,
                to: SIMD2<UInt64>.self
            )

            for lane in 0..<2 {
                let raw = words[lane]
                probeMatches += (
                    UInt64(littleEndian: raw)
                    & scannerHybridHighBits
                ).nonzeroBitCount

                if raw != 0 {
                    scannerHybridSemanticConsumeMaskWord(
                        raw,
                        baseOffset: offset + lane * 8,
                        state: &state
                    )
                }
            }

            offset += 16
        }

        if probeMatches >= minimumMatches {
            scannerHybridSemanticVisitSIMD16(
                bytes: bytes,
                from: offset,
                useMemchrTail: true,
                state: &state
            )
        } else {
            scannerHybridSemanticVisitMemchr(
                bytes: bytes,
                from: offset,
                state: &state
            )
        }
    }

    @inline(__always)
    static func scannerHybridSemanticVisitAdaptive32(
        bytes: UnsafeRawBufferPointer,
        probeByteCount: Int,
        minimumMatches: Int,
        state: inout ScannerHybridLocalSemanticState
    ) {
        guard bytes.count >= probeByteCount,
              let base = bytes.baseAddress
        else {
            scannerHybridSemanticVisitMemchr(
                bytes: bytes,
                from: 0,
                state: &state
            )
            return
        }

        let needle = SIMD32<UInt8>(
            repeating: 0x0A
        )
        var offset = 0
        var probeMatches = 0

        while offset + 32 <= probeByteCount {
            let vector = base
                .advanced(by: offset)
                .loadUnaligned(
                    as: SIMD32<UInt8>.self
                )
            let words = unsafeBitCast(
                vector .== needle,
                to: SIMD4<UInt64>.self
            )

            for lane in 0..<4 {
                let raw = words[lane]
                probeMatches += (
                    UInt64(littleEndian: raw)
                    & scannerHybridHighBits
                ).nonzeroBitCount

                if raw != 0 {
                    scannerHybridSemanticConsumeMaskWord(
                        raw,
                        baseOffset: offset + lane * 8,
                        state: &state
                    )
                }
            }

            offset += 32
        }

        if probeMatches >= minimumMatches {
            scannerHybridSemanticVisitSIMD32(
                bytes: bytes,
                from: offset,
                useMemchrTail: true,
                state: &state
            )
        } else {
            scannerHybridSemanticVisitMemchr(
                bytes: bytes,
                from: offset,
                state: &state
            )
        }
    }

    @inline(__always)
    static func scannerHybridSemanticVisitTail(
        bytes: UnsafeRawBufferPointer,
        from start: Int,
        useMemchr: Bool,
        state: inout ScannerHybridLocalSemanticState
    ) {
        guard start < bytes.count else {
            return
        }

        if useMemchr {
            scannerHybridSemanticVisitMemchr(
                bytes: bytes,
                from: start,
                state: &state
            )
            return
        }

        var index = start

        while index < bytes.count {
            if bytes[index] == 0x0A {
                scannerHybridSemanticConsumeMatch(
                    index,
                    state: &state
                )
            }

            index += 1
        }
    }

    @inline(__always)
    static func scannerHybridSemanticVisitMemchr(
        bytes: UnsafeRawBufferPointer,
        from start: Int,
        state: inout ScannerHybridLocalSemanticState
    ) {
        guard start < bytes.count,
              let base = bytes.baseAddress
        else {
            return
        }

        var offset = start

        while offset < bytes.count {
            let searchBase = base.advanced(
                by: offset
            )
            let searchCount = bytes.count - offset

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
                return
            }

            let index = base.distance(
                to: UnsafeRawPointer(found)
            )
            scannerHybridSemanticConsumeMatch(
                index,
                state: &state
            )
            offset = index + 1
        }
    }

    @inline(__always)
    static func scannerHybridObserveSemantic(
        checksum: inout UInt64,
        lineNumber: UInt64,
        lineStartOffset: UInt64,
        fragmentStartOffset: UInt64,
        fragmentEndOffset: UInt64,
        byteCount: Int,
        ending: ByteLineFragmentEnding
    ) {
        scannerHybridMix(
            &checksum,
            lineNumber
        )
        scannerHybridMix(
            &checksum,
            lineStartOffset
        )
        scannerHybridMix(
            &checksum,
            fragmentStartOffset
        )
        scannerHybridMix(
            &checksum,
            fragmentEndOffset
        )
        scannerHybridMix(
            &checksum,
            UInt64(byteCount)
        )

        switch ending {
        case .none:
            scannerHybridMix(
                &checksum,
                1
            )
        case .line_feed:
            scannerHybridMix(
                &checksum,
                2
            )
        case .end:
            scannerHybridMix(
                &checksum,
                3
            )
        }
    }

    static func scannerHybridTimePositionKernels(
        kernels: [ScannerHybridKernel],
        pattern: [UInt8],
        logicalByteCount: Int,
        rounds: Int,
        scenarioIndex: Int
    ) throws -> [ScannerHybridKernel: ScannerHybridTiming] {
        var expected: [ScannerHybridKernel: ScannerHybridPositionResult] = [:]
        var samples: [ScannerHybridKernel: [UInt64]] = [:]

        for kernel in kernels {
            expected[kernel] = scannerHybridPositionSample(
                pattern: pattern,
                logicalByteCount: logicalByteCount,
                kernel: kernel
            )
        }

        guard let reference = expected[.memchr] else {
            throw TestFailure(
                message: "scanner hybrid missing memchr reference"
            )
        }

        for kernel in kernels {
            try expectEqual(
                expected[kernel],
                reference,
                "scanner hybrid position equivalence \(kernel.label)"
            )
        }

        for round in 0..<rounds {
            let order = scannerHybridInterleavedOrder(
                kernels,
                round: round,
                scenarioIndex: scenarioIndex
            )

            for kernel in order {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = scannerHybridPositionSample(
                    pattern: pattern,
                    logicalByteCount: logicalByteCount,
                    kernel: kernel
                )
                let end = DispatchTime.now().uptimeNanoseconds

                try expectEqual(
                    result,
                    reference,
                    "scanner hybrid timed position \(kernel.label)"
                )
                samples[kernel, default: []].append(
                    end - start
                )
            }
        }

        var timings: [ScannerHybridKernel: ScannerHybridTiming] = [:]

        for kernel in kernels {
            guard let values = samples[kernel],
                  let result = expected[kernel]
            else {
                throw TestFailure(
                    message: "scanner hybrid missing timing \(kernel.label)"
                )
            }

            let sorted = values.sorted()
            timings[kernel] = .init(
                result: result,
                medianNanoseconds: sorted[sorted.count / 2],
                minimumNanoseconds: sorted[0],
                maximumNanoseconds: sorted[sorted.count - 1]
            )
        }

        return timings
    }

    static func scannerHybridPositionSample(
        pattern: [UInt8],
        logicalByteCount: Int,
        kernel: ScannerHybridKernel
    ) -> ScannerHybridPositionResult {
        precondition(logicalByteCount > 0)

        var remaining = logicalByteCount
        var baseOffset: UInt64 = 0
        var lineFeeds: UInt64 = 0
        var checksum: UInt64 = 0

        pattern.withUnsafeBytes { fullPattern in
            while remaining > 0 {
                let count = min(
                    remaining,
                    pattern.count
                )
                let bytes = UnsafeRawBufferPointer(
                    start: fullPattern.baseAddress,
                    count: count
                )
                let result = scannerHybridPositionResult(
                    bytes: bytes,
                    kernel: kernel,
                    baseOffset: baseOffset
                )

                lineFeeds += result.lineFeedCount
                scannerHybridMix(
                    &checksum,
                    result.checksum
                )

                remaining -= count
                baseOffset += UInt64(count)
            }
        }

        return .init(
            lineFeedCount: lineFeeds,
            checksum: checksum
        )
    }

    static func scannerHybridTimeSemanticKernels(
        kernels: [ScannerHybridKernel],
        pattern: [UInt8],
        totalByteCount: Int,
        capacity: BufferCapacity,
        rounds: Int,
        scenarioIndex: Int
    ) throws -> [ScannerHybridKernel: ScannerHybridSemanticTiming] {
        var expected: [ScannerHybridKernel: ScannerHybridSemanticResult] = [:]
        var samples: [ScannerHybridKernel: [UInt64]] = [:]

        for kernel in kernels {
            expected[kernel] = try scannerHybridSemanticScan(
                pattern: pattern,
                totalByteCount: totalByteCount,
                capacity: capacity,
                kernel: kernel
            )
        }

        guard let reference = expected[.memchr] else {
            throw TestFailure(
                message: "scanner hybrid missing semantic memchr reference"
            )
        }

        for kernel in kernels {
            try expectEqual(
                expected[kernel],
                reference,
                "scanner hybrid semantic equivalence \(kernel.label)"
            )
        }

        for round in 0..<rounds {
            let order = scannerHybridInterleavedOrder(
                kernels,
                round: round,
                scenarioIndex: scenarioIndex
            )

            for kernel in order {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = try scannerHybridSemanticScan(
                    pattern: pattern,
                    totalByteCount: totalByteCount,
                    capacity: capacity,
                    kernel: kernel
                )
                let end = DispatchTime.now().uptimeNanoseconds

                try expectEqual(
                    result,
                    reference,
                    "scanner hybrid timed semantic \(kernel.label)"
                )
                samples[kernel, default: []].append(
                    end - start
                )
            }
        }

        var timings: [ScannerHybridKernel: ScannerHybridSemanticTiming] = [:]

        for kernel in kernels {
            guard let values = samples[kernel],
                  let result = expected[kernel]
            else {
                throw TestFailure(
                    message: "scanner hybrid missing semantic timing \(kernel.label)"
                )
            }

            let sorted = values.sorted()
            timings[kernel] = .init(
                result: result,
                medianNanoseconds: sorted[sorted.count / 2],
                minimumNanoseconds: sorted[0],
                maximumNanoseconds: sorted[sorted.count - 1]
            )
        }

        return timings
    }

    static func scannerHybridInterleavedOrder(
        _ kernels: [ScannerHybridKernel],
        round: Int,
        scenarioIndex: Int
    ) -> [ScannerHybridKernel] {
        let shift =
            (round * 3 + scenarioIndex * 5)
            % kernels.count

        var ordered: [ScannerHybridKernel] = []
        ordered.reserveCapacity(
            kernels.count
        )

        for index in kernels.indices {
            ordered.append(
                kernels[(index + shift) % kernels.count]
            )
        }

        if round % 2 == 1 {
            ordered.reverse()
        }

        return ordered
    }

    static func scannerHybridPrintPositionScenario(
        label: String,
        timings: [ScannerHybridKernel: ScannerHybridTiming],
        kernels: [ScannerHybridKernel]
    ) throws {
        guard let baseline = timings[.memchr] else {
            throw TestFailure(
                message: "scanner hybrid missing memchr timing"
            )
        }

        print(
            label
            + " · LF/sample "
            + String(baseline.result.lineFeedCount)
        )

        for kernel in kernels {
            guard let timing = timings[kernel] else {
                continue
            }

            let ratio =
                Double(timing.medianNanoseconds)
                / Double(max(UInt64(1), baseline.medianNanoseconds))

            print(
                "    "
                + kernel.label.padding(
                    toLength: 16,
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
                + "] · vs memchr "
                + String(
                    format: "%.3fx",
                    ratio
                )
            )
        }
    }

    static func scannerHybridPrintSemanticScenario(
        label: String,
        timings: [ScannerHybridKernel: ScannerHybridSemanticTiming],
        kernels: [ScannerHybridKernel]
    ) throws {
        guard let baseline = timings[.memchr] else {
            throw TestFailure(
                message: "scanner hybrid missing semantic memchr timing"
            )
        }

        print(
            label
            + " · fragments/sample "
            + String(baseline.result.fragmentCount)
        )

        for kernel in kernels {
            guard let timing = timings[kernel] else {
                continue
            }

            let ratio =
                Double(timing.medianNanoseconds)
                / Double(max(UInt64(1), baseline.medianNanoseconds))

            print(
                "    "
                + kernel.label.padding(
                    toLength: 16,
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
                + "] · vs memchr "
                + String(
                    format: "%.3fx",
                    ratio
                )
            )
        }
    }
}
