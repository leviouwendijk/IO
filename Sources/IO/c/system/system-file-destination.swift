#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum SystemFileDestinationMode: Sendable, Equatable {
    /// Create a new file and fail if the path already exists.
    case create

    /// Create the file if needed, or truncate an existing file before writing.
    case truncate

    /// Create the file if needed and atomically append each write at the kernel boundary.
    case append
}

public enum SystemFileDestinationError: Error, Sendable, Equatable {
    case open(path: String, code: Int32)
    case write(path: String, code: Int32)
    case close(path: String, code: Int32)
    case closed(path: String)
}

/// Uniquely-owned synchronous POSIX file destination backend.
///
/// `Destination` owns user-space staging and backpressure. This backend owns only the
/// descriptor and syscall boundary:
///
/// - scalar drains use `write(2)`;
/// - two-region drains use the package's fixed-stack `writev(2)` adapter;
/// - short writes are returned as short progress rather than hidden;
/// - `EINTR` is retried mechanically because Destination has no retry state;
/// - `EAGAIN` / `EWOULDBLOCK` surface as `.unavailable`;
/// - `flush()` is logical only and does not imply `fsync`.
///
/// Durability is intentionally separate from logical Destination flushing.
public struct SystemFileDestination: DestinationBackend, ~Copyable {
    public let path: String
    public let mode: SystemFileDestinationMode

    private var descriptor: Int32

    /// Opens a uniquely-owned file destination.
    ///
    /// `permissions` is used only when the open operation creates a file and remains
    /// subject to the process umask.
    public init(
        path: String,
        mode: SystemFileDestinationMode = .truncate,
        permissions: UInt16 = 0o666
    ) throws {
        let descriptor = path.withCString { pointer in
            systemDestinationOpen(
                pointer,
                mode: mode,
                permissions: permissions
            )
        }

        guard descriptor >= 0 else {
            throw SystemFileDestinationError.open(
                path: path,
                code: errno
            )
        }

        switch POSIXBrokenPipeSignal.suppress(
            descriptor: descriptor
        ) {
        case .suppressed, .not_applicable:
            break

        case .socket_already_shut_down:
            // A write would raise SIGPIPE; refuse the destination instead.
            _ = systemDestinationClose(
                descriptor
            )
            throw SystemFileDestinationError.open(
                path: path,
                code: EPIPE
            )

        case .failed(let code):
            _ = systemDestinationClose(
                descriptor
            )
            throw SystemFileDestinationError.open(
                path: path,
                code: code
            )
        }

        self.path = path
        self.mode = mode
        self.descriptor = descriptor
    }

    deinit {
        if descriptor >= 0 {
            _ = systemDestinationClose(
                descriptor
            )
        }
    }

    public mutating func drain(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        guard descriptor >= 0 else {
            throw SystemFileDestinationError.closed(
                path: path
            )
        }

        guard !bytes.isEmpty else {
            return .unavailable
        }

        while true {
            let result = systemDestinationWrite(
                descriptor,
                bytes.baseAddress,
                POSIXTransferLimit.clamp(
                    bytes.count
                )
            )

            if result > 0 {
                return .bytes(
                    .knownPositive(
                        result
                    )
                )
            }

            if result == 0 {
                return .unavailable
            }

            let code = errno

            if code == EINTR {
                continue
            }

            if code == EAGAIN
                || code == EWOULDBLOCK
            {
                return .unavailable
            }

            throw SystemFileDestinationError.write(
                path: path,
                code: code
            )
        }
    }

    public mutating func drain(
        first: UnsafeRawBufferPointer,
        second: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        guard descriptor >= 0 else {
            throw SystemFileDestinationError.closed(
                path: path
            )
        }

        guard !first.isEmpty
                || !second.isEmpty
        else {
            return .unavailable
        }

        while true {
            do {
                switch try POSIXVectorIO.writev(
                    descriptor: descriptor,
                    first: first,
                    second: second
                ) {
                case .bytes(let count):
                    return .bytes(
                        .knownPositive(
                            count
                        )
                    )

                case .unavailable,
                     .end:
                    return .unavailable

                case .retry:
                    continue
                }
            } catch let error as POSIXIOError {
                throw SystemFileDestinationError.write(
                    path: path,
                    code: error.code
                )
            }
        }
    }

    public mutating func flush() throws -> DestinationFlush {
        guard descriptor >= 0 else {
            throw SystemFileDestinationError.closed(
                path: path
            )
        }

        // Destination.flush() means "drain user-space staging and ask the backend to
        // logically flush". It intentionally does not make every flush an fsync.
        return .complete
    }

    public mutating func close() throws {
        guard descriptor >= 0 else {
            return
        }

        let openDescriptor = descriptor
        descriptor = -1

        guard systemDestinationClose(
            openDescriptor
        ) == 0 else {
            throw SystemFileDestinationError.close(
                path: path,
                code: errno
            )
        }
    }
}

@inline(__always)
private func systemDestinationOpen(
    _ path: UnsafePointer<CChar>,
    mode: SystemFileDestinationMode,
    permissions: UInt16
) -> Int32 {
    let flags: Int32

    switch mode {
    case .create:
        flags =
            O_WRONLY
            | O_CREAT
            | O_EXCL

    case .truncate:
        flags =
            O_WRONLY
            | O_CREAT
            | O_TRUNC

    case .append:
        flags =
            O_WRONLY
            | O_CREAT
            | O_APPEND
    }

    #if canImport(Darwin)
    return Darwin.open(
        path,
        flags,
        mode_t(permissions)
    )
    #elseif canImport(Glibc)
    return Glibc.open(
        path,
        flags,
        mode_t(permissions)
    )
    #endif
}

@inline(__always)
private func systemDestinationWrite(
    _ descriptor: Int32,
    _ buffer: UnsafeRawPointer?,
    _ count: Int
) -> Int {
    #if canImport(Darwin)
    Darwin.write(
        descriptor,
        buffer,
        count
    )
    #elseif canImport(Glibc)
    Glibc.write(
        descriptor,
        buffer,
        count
    )
    #endif
}

@inline(__always)
private func systemDestinationClose(
    _ descriptor: Int32
) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(descriptor)
    #elseif canImport(Glibc)
    Glibc.close(descriptor)
    #endif
}
