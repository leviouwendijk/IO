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
    static func walk(
        _ bytes: UnsafeRawBufferPointer,
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
public enum ByteMatch {
    private static let highBits: UInt64 = 0x8080_8080_8080_8080

    public enum libc: ByteMatchKernel {
        @inline(__always)
        public static func walk(
            _ bytes: UnsafeRawBufferPointer,
            needle: UInt8,
            from start: Int = 0,
            _ body: (Int) throws -> ByteMatchDirective
        ) rethrows -> ByteMatchWalkResult {
            precondition(start >= 0 && start <= bytes.count)

            guard let base = bytes.baseAddress else {
                return .complete
            }

            var offset = start

            while offset < bytes.count {
                let search = base.advanced(by: offset)
                let count = bytes.count - offset

                guard let match = memchr(
                    search,
                    Int32(needle),
                    count
                ) else {
                    return .complete
                }

                let index = base.distance(
                    to: UnsafeRawPointer(match)
                )

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
            _ bytes: UnsafeRawBufferPointer,
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
            _ bytes: UnsafeRawBufferPointer,
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
            _ bytes: UnsafeRawBufferPointer,
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
        _ bytes: UnsafeRawBufferPointer,
        needle byte: UInt8,
        from start: Int,
        _ body: (Int) throws -> ByteMatchDirective
    ) rethrows -> ByteMatchWalkResult {
        precondition(start >= 0 && start <= bytes.count)

        guard let base = bytes.baseAddress else {
            return .complete
        }

        let needle = SIMD16<UInt8>(repeating: byte)
        var offset = start

        while offset + 16 <= bytes.count {
            let vector = base.advanced(by: offset).loadUnaligned(as: SIMD16<UInt8>.self)
            let words = unsafeBitCast(vector .== needle, to: SIMD2<UInt64>.self)

            if words[0] != 0,
               case .stopped(let index) = try walkMaskWord(words[0], baseOffset: offset, body)
            {
                return .stopped(at: index)
            }

            if words[1] != 0,
               case .stopped(let index) = try walkMaskWord(words[1], baseOffset: offset + 8, body)
            {
                return .stopped(at: index)
            }

            offset += 16
        }

        return try libc.walk(bytes, needle: byte, from: offset, body)
    }

    @inline(__always)
    private static func walkSIMD32(
        _ bytes: UnsafeRawBufferPointer,
        needle byte: UInt8,
        from start: Int,
        _ body: (Int) throws -> ByteMatchDirective
    ) rethrows -> ByteMatchWalkResult {
        precondition(start >= 0 && start <= bytes.count)

        guard let base = bytes.baseAddress else {
            return .complete
        }

        let needle = SIMD32<UInt8>(repeating: byte)
        var offset = start

        while offset + 32 <= bytes.count {
            let vector = base.advanced(by: offset).loadUnaligned(as: SIMD32<UInt8>.self)
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
        _ bytes: UnsafeRawBufferPointer,
        needle byte: UInt8,
        from start: Int,
        _ body: (Int) throws -> ByteMatchDirective
    ) rethrows -> ByteMatchWalkResult {
        precondition(start >= 0 && start <= bytes.count)

        guard let base = bytes.baseAddress else {
            return .complete
        }

        let needle = SIMD64<UInt8>(repeating: byte)
        var offset = start

        while offset + 64 <= bytes.count {
            let vector = base.advanced(by: offset).loadUnaligned(as: SIMD64<UInt8>.self)
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
