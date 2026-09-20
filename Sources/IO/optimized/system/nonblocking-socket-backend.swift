#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Shared duplex POSIX socket endpoint suitable for one `Source` and one `Destination`.
///
/// Reference semantics are deliberate here: a socket is intrinsically duplex, while the
/// byte-stream wrappers keep independent read/write buffering north of this endpoint.
/// The descriptor is closed exactly once by this object when ownership is enabled.
public final class NonblockingSocketBackend: SourceBackend, DestinationBackend, @unchecked Sendable {
    public let descriptor: Int32
    private let ownsDescriptor: Bool
    private var closed: Bool

    public init(
        descriptor: Int32,
        setNonblocking: Bool = true,
        ownsDescriptor: Bool = true
    ) throws {
        self.descriptor = descriptor
        self.ownsDescriptor = ownsDescriptor
        self.closed = false

        if setNonblocking {
            try Self.makeNonblocking(descriptor)
        }
    }

    deinit {
        if ownsDescriptor && !closed {
            #if canImport(Darwin)
            _ = Darwin.close(descriptor)
            #elseif canImport(Glibc)
            _ = Glibc.close(descriptor)
            #endif
        }
    }

    public func close() throws {
        guard !closed else { return }
        closed = true
        guard ownsDescriptor else { return }

        #if canImport(Darwin)
        let result = Darwin.close(descriptor)
        #elseif canImport(Glibc)
        let result = Glibc.close(descriptor)
        #endif

        guard result == 0 else {
            throw POSIXIOError(operation: "close", code: errno)
        }
    }

    public func refill(
        into bytes: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        guard !bytes.isEmpty else { return .unavailable }

        #if canImport(Darwin)
        let result = Darwin.recv(descriptor, bytes.baseAddress, bytes.count, 0)
        #elseif canImport(Glibc)
        let result = Glibc.recv(descriptor, bytes.baseAddress, bytes.count, 0)
        #endif

        if result > 0 {
            return .bytes(.knownPositive(result))
        }
        if result == 0 {
            return .end
        }

        let code = errno
        if code == EINTR {
            return .retry
        }
        if code == EAGAIN || code == EWOULDBLOCK {
            return .unavailable
        }
        throw POSIXIOError(operation: "recv", code: code)
    }

    public func drain(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        guard !bytes.isEmpty else { return .unavailable }

        #if canImport(Darwin)
        let result = Darwin.send(descriptor, bytes.baseAddress, bytes.count, 0)
        #elseif canImport(Glibc)
        let result = Glibc.send(descriptor, bytes.baseAddress, bytes.count, Int32(MSG_NOSIGNAL))
        #endif

        if result > 0 {
            return .bytes(.knownPositive(result))
        }

        let code = errno
        if code == EINTR {
            return try drain(bytes)
        }
        if code == EAGAIN || code == EWOULDBLOCK {
            return .unavailable
        }
        throw POSIXIOError(operation: "send", code: code)
    }

    public func flush() throws -> DestinationFlush {
        .complete
    }

    public func inspect() -> DestinationBackendInspection {
        .init()
    }

    private static func makeNonblocking(
        _ descriptor: Int32
    ) throws {
        #if canImport(Darwin)
        let current = Darwin.fcntl(descriptor, F_GETFL)
        #elseif canImport(Glibc)
        let current = Glibc.fcntl(descriptor, F_GETFL)
        #endif

        guard current >= 0 else {
            throw POSIXIOError(operation: "fcntl(F_GETFL)", code: errno)
        }

        #if canImport(Darwin)
        let result = Darwin.fcntl(descriptor, F_SETFL, current | O_NONBLOCK)
        #elseif canImport(Glibc)
        let result = Glibc.fcntl(descriptor, F_SETFL, current | O_NONBLOCK)
        #endif

        guard result == 0 else {
            throw POSIXIOError(operation: "fcntl(F_SETFL)", code: errno)
        }
    }
}

public extension NonblockingSocketBackend {
    func refill(
        first: UnsafeMutableRawBufferPointer,
        second: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        guard !first.isEmpty || !second.isEmpty else {
            return .unavailable
        }

        while true {
            switch try POSIXVectorIO.readv(
                descriptor: descriptor,
                first: first,
                second: second
            ) {
            case .bytes(let count):
                return .bytes(.knownPositive(count))
            case .end:
                return .end
            case .unavailable:
                return .unavailable
            case .retry:
                continue
            }
        }
    }

    func drain(
        first: UnsafeRawBufferPointer,
        second: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        guard !first.isEmpty || !second.isEmpty else {
            return .unavailable
        }

        while true {
            switch try POSIXVectorIO.writev(
                descriptor: descriptor,
                first: first,
                second: second
            ) {
            case .bytes(let count):
                return .bytes(.knownPositive(count))
            case .unavailable:
                return .unavailable
            case .retry:
                continue
            case .end:
                return .unavailable
            }
        }
    }
}

