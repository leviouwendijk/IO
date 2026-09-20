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
