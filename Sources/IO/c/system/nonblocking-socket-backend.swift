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
///
/// Lifecycle: every syscall on `descriptor` runs under the same lock as `close()`, and
/// is refused once the backend is closed. A closed backend therefore can never touch a
/// descriptor number the kernel has since handed to an unrelated resource.
///
/// Broken pipes: a write to a socket whose peer has gone away reports `EPIPE` through
/// `POSIXIOError` instead of raising `SIGPIPE` (`SO_NOSIGPIPE` on Darwin, per-call
/// `MSG_NOSIGNAL` on Linux). Darwin refuses `SO_NOSIGPIPE` on a socket that is already
/// shut down in both directions; such a socket is still adopted, but its writes are
/// refused with `EPIPE` without entering the kernel, because the kernel would raise
/// `SIGPIPE` for them.
public final class NonblockingSocketBackend: SourceBackend, DestinationBackend, @unchecked Sendable {
    public let descriptor: Int32
    private let ownsDescriptor: Bool
    private let lifecycle: UnsafeMutablePointer<pthread_mutex_t>
    private let writesKnownBroken: Bool
    private var closed: Bool

    public var readinessDescriptor: Int32? {
        withLifecycle {
            closed
                ? nil
                : descriptor
        }
    }

    public init(
        descriptor: Int32,
        setNonblocking: Bool = true,
        ownsDescriptor: Bool = true
    ) throws {
        let suppression = POSIXBrokenPipeSignal.suppress(
            descriptor: descriptor
        )

        self.descriptor = descriptor
        self.ownsDescriptor = ownsDescriptor
        self.lifecycle = .allocate(capacity: 1)
        self.writesKnownBroken = suppression == .socket_already_shut_down
        self.closed = false
        _ = pthread_mutex_init(lifecycle, nil)

        if setNonblocking {
            try Self.makeNonblocking(descriptor)
        }

        if case .failed(let code) = suppression {
            throw POSIXIOError(operation: "suppress SIGPIPE", code: code)
        }
    }

    deinit {
        if ownsDescriptor && !closed {
            _ = socketSystemClose(descriptor)
        }

        _ = pthread_mutex_destroy(lifecycle)
        lifecycle.deallocate()
    }

    public func close() throws {
        let failure: Int32? = withLifecycle {
            guard !closed else { return nil }
            closed = true
            guard ownsDescriptor else { return nil }

            return socketSystemClose(descriptor) == 0
                ? nil
                : errno
        }

        if let failure {
            throw POSIXIOError(operation: "close", code: failure)
        }
    }

    public func refill(
        into bytes: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        guard !bytes.isEmpty else { return .unavailable }

        return try withOpenDescriptor(operation: "recv") { descriptor in
            let result = socketSystemReceive(
                descriptor,
                bytes.baseAddress,
                POSIXTransferLimit.clamp(bytes.count)
            )

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
    }

    public func refill(
        first: UnsafeMutableRawBufferPointer,
        second: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        guard !first.isEmpty || !second.isEmpty else {
            return .unavailable
        }

        return try withOpenDescriptor(operation: "readv") { descriptor in
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
    }

    public func drain(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        guard !bytes.isEmpty else { return .unavailable }

        return try withWritableDescriptor(operation: "send") { descriptor in
            while true {
                let result = socketSystemSend(
                    descriptor,
                    bytes.baseAddress,
                    POSIXTransferLimit.clamp(bytes.count),
                    POSIXBrokenPipeSignal.sendFlags
                )

                if result > 0 {
                    return .bytes(.knownPositive(result))
                }

                let code = errno

                if code == EINTR {
                    continue
                }

                if code == EAGAIN || code == EWOULDBLOCK {
                    return .unavailable
                }

                throw POSIXIOError(operation: "send", code: code)
            }
        }
    }

    /// Two-region drain through `sendmsg`, so the per-call broken-pipe flag applies to
    /// the vector path exactly as it does to the scalar path.
    public func drain(
        first: UnsafeRawBufferPointer,
        second: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        guard !first.isEmpty || !second.isEmpty else {
            return .unavailable
        }

        return try withWritableDescriptor(operation: "sendmsg") { descriptor in
            while true {
                switch try POSIXVectorIO.sendmsg(
                    descriptor: descriptor,
                    first: first,
                    second: second,
                    flags: POSIXBrokenPipeSignal.sendFlags
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

    public func flush() throws -> DestinationFlush {
        .complete
    }

    public func inspect() -> DestinationBackendInspection {
        .init()
    }

    private func withLifecycle<Result>(
        _ body: () throws -> Result
    ) rethrows -> Result {
        _ = pthread_mutex_lock(lifecycle)
        defer { _ = pthread_mutex_unlock(lifecycle) }
        return try body()
    }

    /// Runs one syscall sequence while holding the lifecycle lock, refusing with
    /// `EBADF` once the backend has been closed.
    private func withOpenDescriptor<Result>(
        operation: String,
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        try withLifecycle {
            guard !closed else {
                throw POSIXIOError(operation: operation, code: EBADF)
            }

            return try body(descriptor)
        }
    }

    /// Write-side variant of `withOpenDescriptor`: additionally refuses with `EPIPE`
    /// when the socket was adopted after being shut down, since Darwin would raise
    /// `SIGPIPE` for any write to it.
    private func withWritableDescriptor<Result>(
        operation: String,
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        try withOpenDescriptor(operation: operation) { descriptor in
            guard !writesKnownBroken else {
                throw POSIXIOError(operation: operation, code: EPIPE)
            }

            return try body(descriptor)
        }
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

@inline(__always)
private func socketSystemClose(
    _ descriptor: Int32
) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(descriptor)
    #elseif canImport(Glibc)
    Glibc.close(descriptor)
    #endif
}

@inline(__always)
private func socketSystemReceive(
    _ descriptor: Int32,
    _ buffer: UnsafeMutableRawPointer?,
    _ count: Int
) -> Int {
    #if canImport(Darwin)
    Darwin.recv(descriptor, buffer, count, 0)
    #elseif canImport(Glibc)
    Glibc.recv(descriptor, buffer, count, 0)
    #endif
}

@inline(__always)
private func socketSystemSend(
    _ descriptor: Int32,
    _ buffer: UnsafeRawPointer?,
    _ count: Int,
    _ flags: Int32
) -> Int {
    #if canImport(Darwin)
    Darwin.send(descriptor, buffer, count, flags)
    #elseif canImport(Glibc)
    Glibc.send(descriptor, buffer, count, flags)
    #endif
}
