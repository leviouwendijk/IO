#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct POSIXIOError: Error, Sendable, Equatable, CustomStringConvertible {
    public let operation: String
    public let code: Int32

    public init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }

    public var description: String {
        "\(operation) failed with errno \(code)"
    }
}

package enum POSIXVectorProgress: Equatable {
    case bytes(Int)
    case end
    case unavailable
    case retry
}

/// Low-level scatter/gather syscall adapters used by experiments around ring buffers.
///
/// The adapter uses a fixed temporary two-entry `iovec` buffer rather than constructing
/// a Swift Array on every syscall. Ring storage has at most two physical regions, so a
/// heap-backed vector container would add allocation/ARC noise to the hot boundary being
/// measured.
package enum POSIXVectorIO {
    package static func readv(
        descriptor: Int32,
        first: UnsafeMutableRawBufferPointer,
        second: UnsafeMutableRawBufferPointer
    ) throws -> POSIXVectorProgress {
        let result = withUnsafeTemporaryAllocation(
            of: iovec.self,
            capacity: 2
        ) { vectors -> Int in
            let count = fillMutableIOVectors(
                vectors,
                first: first,
                second: second
            )
            guard count > 0 else { return 0 }

            #if canImport(Darwin)
            return Darwin.readv(descriptor, vectors.baseAddress, Int32(count))
            #elseif canImport(Glibc)
            return Glibc.readv(descriptor, vectors.baseAddress, Int32(count))
            #endif
        }

        if first.isEmpty && second.isEmpty {
            return .unavailable
        }
        return try readProgress(result, operation: "readv")
    }

    package static func writev(
        descriptor: Int32,
        first: UnsafeRawBufferPointer,
        second: UnsafeRawBufferPointer
    ) throws -> POSIXVectorProgress {
        let result = withUnsafeTemporaryAllocation(
            of: iovec.self,
            capacity: 2
        ) { vectors -> Int in
            let count = fillIOVectors(
                vectors,
                first: first,
                second: second
            )
            guard count > 0 else { return 0 }

            #if canImport(Darwin)
            return Darwin.writev(descriptor, vectors.baseAddress, Int32(count))
            #elseif canImport(Glibc)
            return Glibc.writev(descriptor, vectors.baseAddress, Int32(count))
            #endif
        }

        return try writeProgress(result, operation: "writev")
    }

    package static func sendmsg(
        descriptor: Int32,
        first: UnsafeRawBufferPointer,
        second: UnsafeRawBufferPointer,
        flags: Int32 = 0
    ) throws -> POSIXVectorProgress {
        let result = withUnsafeTemporaryAllocation(
            of: iovec.self,
            capacity: 2
        ) { vectors -> Int in
            let count = fillIOVectors(
                vectors,
                first: first,
                second: second
            )
            guard count > 0 else { return 0 }

            var message = msghdr()
            message.msg_iov = vectors.baseAddress

            #if canImport(Darwin)
            message.msg_iovlen = Int32(count)
            return Darwin.sendmsg(descriptor, &message, flags)
            #elseif canImport(Glibc)
            message.msg_iovlen = count
            return Glibc.sendmsg(descriptor, &message, flags)
            #endif
        }

        return try writeProgress(result, operation: "sendmsg")
    }

    private static func fillMutableIOVectors(
        _ vectors: UnsafeMutableBufferPointer<iovec>,
        first: UnsafeMutableRawBufferPointer,
        second: UnsafeMutableRawBufferPointer
    ) -> Int {
        var count = 0
        if !first.isEmpty {
            vectors[count] = iovec(
                iov_base: first.baseAddress,
                iov_len: first.count
            )
            count += 1
        }
        if !second.isEmpty {
            vectors[count] = iovec(
                iov_base: second.baseAddress,
                iov_len: second.count
            )
            count += 1
        }
        return count
    }

    private static func fillIOVectors(
        _ vectors: UnsafeMutableBufferPointer<iovec>,
        first: UnsafeRawBufferPointer,
        second: UnsafeRawBufferPointer
    ) -> Int {
        var count = 0
        if !first.isEmpty {
            vectors[count] = iovec(
                iov_base: UnsafeMutableRawPointer(mutating: first.baseAddress),
                iov_len: first.count
            )
            count += 1
        }
        if !second.isEmpty {
            vectors[count] = iovec(
                iov_base: UnsafeMutableRawPointer(mutating: second.baseAddress),
                iov_len: second.count
            )
            count += 1
        }
        return count
    }

    private static func readProgress(
        _ result: Int,
        operation: String
    ) throws -> POSIXVectorProgress {
        if result > 0 { return .bytes(result) }
        if result == 0 { return .end }
        return try errnoProgress(operation: operation)
    }

    private static func writeProgress(
        _ result: Int,
        operation: String
    ) throws -> POSIXVectorProgress {
        if result > 0 { return .bytes(result) }
        if result == 0 { return .unavailable }
        return try errnoProgress(operation: operation)
    }

    private static func errnoProgress(
        operation: String
    ) throws -> POSIXVectorProgress {
        let code = errno
        if code == EINTR {
            return .retry
        }
        if code == EAGAIN || code == EWOULDBLOCK {
            return .unavailable
        }
        throw POSIXIOError(operation: operation, code: code)
    }
}

/// Converts "write with no remaining reader" from a process-killing `SIGPIPE` into an
/// ordinary `EPIPE` failure.
///
/// Darwin: sockets use `SO_NOSIGPIPE`, pipes/FIFOs use `F_SETNOSIGPIPE`; other descriptor
/// kinds are left untouched. Linux has no per-descriptor switch: socket writes pass
/// `MSG_NOSIGNAL` per call (`sendFlags`), and pipe `SIGPIPE` policy remains the
/// process's responsibility.
package enum POSIXBrokenPipeSignal {
    package enum Suppression: Sendable, Equatable {
        /// Writes on the descriptor now report `EPIPE` instead of raising `SIGPIPE`.
        case suppressed

        /// The descriptor kind never raises `SIGPIPE` (regular file, device, ...), or the
        /// platform handles it per call (`sendFlags` on Linux).
        case not_applicable

        /// Darwin refused `SO_NOSIGPIPE` with `EINVAL` because the socket is already shut
        /// down in both directions. Any write would fail with `EPIPE` *and* raise
        /// `SIGPIPE`, so owners must refuse writes rather than issue them.
        case socket_already_shut_down

        /// Configuration failed with this errno.
        case failed(Int32)
    }

    package static func suppress(
        descriptor: Int32
    ) -> Suppression {
        #if canImport(Darwin)
        var info = stat()

        guard Darwin.fstat(descriptor, &info) == 0 else {
            return .failed(errno)
        }

        let kind = info.st_mode & mode_t(S_IFMT)

        if kind == mode_t(S_IFSOCK) {
            var enabled: Int32 = 1
            let result = Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &enabled,
                socklen_t(MemoryLayout<Int32>.size)
            )

            if result == 0 {
                return .suppressed
            }

            let code = errno
            return code == EINVAL
                ? .socket_already_shut_down
                : .failed(code)
        }

        if kind == mode_t(S_IFIFO) {
            return Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0
                ? .suppressed
                : .failed(errno)
        }

        return .not_applicable
        #else
        _ = descriptor
        return .not_applicable
        #endif
    }

    /// Per-call flags for socket sends.
    package static var sendFlags: Int32 {
        #if canImport(Glibc)
        Int32(MSG_NOSIGNAL)
        #else
        0
        #endif
    }
}
