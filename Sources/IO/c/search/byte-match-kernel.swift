#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Control returned while walking byte matches.
public enum ByteMatchDirective: Sendable, Equatable {
    case `continue`
    case stop
}

/// Result of walking one borrowed byte span.
public enum ByteMatchWalkResult: Sendable, Equatable {
    case complete
    case stopped(at: Int)
}

/// Compile-time-selectable byte-search kernel.
///
/// Kernels are expressed as static operations so generic consumers can select an
/// implementation per task without introducing an existential/witness-table call in the
/// hot search loop. Runtime erasure can be layered above this later if configuration
/// requires it.
public protocol ByteMatchKernel {
    /// Reports each index of `needle` in `bytes`, at or after `start` and in ascending
    /// order, until `body` returns `.stop`.
    ///
    /// `bytes` is a borrowed, non-escapable view of Source-owned storage: a kernel can read
    /// it for the duration of the call but cannot retain it.
    static func walk(
        _ bytes: RawSpan,
        needle: UInt8,
        from start: Int,
        _ body: (Int) throws -> ByteMatchDirective
    ) rethrows -> ByteMatchWalkResult
}

/// Built-in byte-search kernels.
///
/// `libc` is the default for next-match/control-heavy scanners such as
/// `ByteLineScanner`. The SIMD kernels are retained for tasks that profit from discovering
/// many matches per wide load (line indexing, structural indexing, dense delimiters).
///
/// Every kernel touches raw memory only inside `RawSpan.withUnsafeBytes`, and always
/// invokes `body` outside that scope.
public enum ByteMatch {
    private static let highBits: UInt64 = 0x8080_8080_8080_8080

    public enum libc: ByteMatchKernel {
        @inline(__always)
        public static func walk(
            _ bytes: RawSpan,
            needle: UInt8,
            from start: Int = 0,
            _ body: (Int) throws -> ByteMatchDirective
        ) rethrows -> ByteMatchWalkResult {
            precondition(start >= 0 && start <= bytes.byteCount)

            var offset = start

            while offset < bytes.byteCount {
                guard let index = nextMatch(
                    in: bytes,
                    needle: needle,
                    from: offset
                ) else {
                    return .complete
                }

                if try body(index) == .stop {
                    return .stopped(at: index)
                }

                offset = index + 1
            }

            return .complete
        }
    }

    public enum simd16: ByteMatchKernel {
        @inline(__always)
        public static func walk(
            _ bytes: RawSpan,
            needle: UInt8,
            from start: Int = 0,
            _ body: (Int) throws -> ByteMatchDirective
        ) rethrows -> ByteMatchWalkResult {
            try walkSIMD16(
                bytes,
                needle: needle,
                from: start,
                body
            )
        }
    }

    public enum simd32: ByteMatchKernel {
        @inline(__always)
        public static func walk(
            _ bytes: RawSpan,
            needle: UInt8,
            from start: Int = 0,
            _ body: (Int) throws -> ByteMatchDirective
        ) rethrows -> ByteMatchWalkResult {
            try walkSIMD32(
                bytes,
                needle: needle,
                from: start,
                body
            )
        }
    }

    public enum simd64: ByteMatchKernel {
        @inline(__always)
        public static func walk(
            _ bytes: RawSpan,
            needle: UInt8,
            from start: Int = 0,
            _ body: (Int) throws -> ByteMatchDirective
        ) rethrows -> ByteMatchWalkResult {
            try walkSIMD64(
                bytes,
                needle: needle,
                from: start,
                body
            )
        }
    }

    /// `memchr` from `offset`; returns the absolute index of the next match.
    @inline(__always)
    private static func nextMatch(
        in bytes: RawSpan,
        needle: UInt8,
        from offset: Int
    ) -> Int? {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress,
                  offset < buffer.count,
                  let match = memchr(
                    base.advanced(by: offset),
                    Int32(needle),
                    buffer.count - offset
                  )
            else {
                return nil
            }

            return base.distance(
                to: UnsafeRawPointer(match)
            )
        }
    }

    @inline(__always)
    private static func walkMaskWord(
        _ rawWord: UInt64,
        baseOffset: Int,
        _ body: (Int) throws -> ByteMatchDirective
    ) rethrows -> ByteMatchWalkResult {
        var mask = UInt64(littleEndian: rawWord) & highBits

        while mask != 0 {
            let byteOffset = mask.trailingZeroBitCount >> 3
            let index = baseOffset + byteOffset

            if try body(index) == .stop {
                return .stopped(at: index)
            }

            mask &= mask &- 1
        }

        return .complete
    }

    @inline(__always)
    private static func walkSIMD16(
        _ bytes: RawSpan,
        needle byte: UInt8,
        from start: Int,
        _ body: (Int) throws -> ByteMatchDirective
    ) rethrows -> ByteMatchWalkResult {
        precondition(start >= 0 && start <= bytes.byteCount)

        let needle = SIMD16<UInt8>(repeating: byte)
        var offset = start

        while offset + 16 <= bytes.byteCount {
            // In bounds by the loop condition; the pointer never leaves the closure.
            let vector = bytes.withUnsafeBytes { buffer in
                buffer.baseAddress!
                    .advanced(by: offset)
                    .loadUnaligned(as: SIMD16<UInt8>.self)
            }
            let words = unsafeBitCast(vector .== needle, to: SIMD2<UInt64>.self)

            for lane in 0..<2 where words[lane] != 0 {
                if case .stopped(let index) = try walkMaskWord(
                    words[lane],
                    baseOffset: offset + lane * 8,
                    body
                ) {
                    return .stopped(at: index)
                }
            }

            offset += 16
        }

        return try libc.walk(bytes, needle: byte, from: offset, body)
    }

    @inline(__always)
    private static func walkSIMD32(
        _ bytes: RawSpan,
        needle byte: UInt8,
        from start: Int,
        _ body: (Int) throws -> ByteMatchDirective
    ) rethrows -> ByteMatchWalkResult {
        precondition(start >= 0 && start <= bytes.byteCount)

        let needle = SIMD32<UInt8>(repeating: byte)
        var offset = start

        while offset + 32 <= bytes.byteCount {
            // In bounds by the loop condition; the pointer never leaves the closure.
            let vector = bytes.withUnsafeBytes { buffer in
                buffer.baseAddress!
                    .advanced(by: offset)
                    .loadUnaligned(as: SIMD32<UInt8>.self)
            }
            let words = unsafeBitCast(vector .== needle, to: SIMD4<UInt64>.self)

            for lane in 0..<4 where words[lane] != 0 {
                if case .stopped(let index) = try walkMaskWord(
                    words[lane],
                    baseOffset: offset + lane * 8,
                    body
                ) {
                    return .stopped(at: index)
                }
            }

            offset += 32
        }

        return try libc.walk(bytes, needle: byte, from: offset, body)
    }

    @inline(__always)
    private static func walkSIMD64(
        _ bytes: RawSpan,
        needle byte: UInt8,
        from start: Int,
        _ body: (Int) throws -> ByteMatchDirective
    ) rethrows -> ByteMatchWalkResult {
        precondition(start >= 0 && start <= bytes.byteCount)

        let needle = SIMD64<UInt8>(repeating: byte)
        var offset = start

        while offset + 64 <= bytes.byteCount {
            // In bounds by the loop condition; the pointer never leaves the closure.
            let vector = bytes.withUnsafeBytes { buffer in
                buffer.baseAddress!
                    .advanced(by: offset)
                    .loadUnaligned(as: SIMD64<UInt8>.self)
            }
            let words = unsafeBitCast(vector .== needle, to: SIMD8<UInt64>.self)

            for lane in 0..<8 where words[lane] != 0 {
                if case .stopped(let index) = try walkMaskWord(
                    words[lane],
                    baseOffset: offset + lane * 8,
                    body
                ) {
                    return .stopped(at: index)
                }
            }

            offset += 64
        }

        return try libc.walk(bytes, needle: byte, from: offset, body)
    }
}
