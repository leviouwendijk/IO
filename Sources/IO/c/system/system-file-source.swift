import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum SystemFileSourceError: Error, Sendable, Equatable {
    case open(path: String, code: Int32)
    case cache(path: String, code: Int32)
    case inspect(path: String, code: Int32)
    case read(path: String, code: Int32)
    case close(path: String, code: Int32)
    case closed(path: String)
}

public extension SystemFileSourceError {
    /// The same failure as a `FileSystemError`, for callers that report
    /// filesystem errors one way. nil for `.closed`, which has no errno.
    var fileSystemError: FileSystemError? {
        switch self {
        case .open(let path, let code), .cache(let path, let code):
            return .init(operation: .open, url: URL(fileURLWithPath: path), errno: code)
        case .inspect(let path, let code):
            return .init(operation: .inspect, url: URL(fileURLWithPath: path), errno: code)
        case .read(let path, let code):
            return .init(operation: .read, url: URL(fileURLWithPath: path), errno: code)
        case .close(let path, let code):
            return .init(operation: .close, url: URL(fileURLWithPath: path), errno: code)
        case .closed:
            return nil
        }
    }
}

/// Uniquely-owned synchronous POSIX file backend.
///
/// The descriptor is stored in a noncopyable value so ownership transfer into `Source`
/// cannot accidentally leave another mutable alias to the file cursor. Each `refill`
/// performs exactly one `read(2)` call. `EINTR` is reported as `.retry`, allowing Source
/// to retry while keeping an exact refill-call == read-syscall count.
public struct SystemFileSource: SourceBackend, ~Copyable {
    public let path: String

    private var descriptor: Int32

    /// `openNonblocking` opens with `O_NONBLOCK`: opening a FIFO returns
    /// immediately instead of waiting for a writer, and its reads report
    /// `.unavailable` instead of blocking. Regular-file reads are unaffected,
    /// so a caller that refuses non-regular files after `inspect()` gets that
    /// guarantee without an extra syscall.
    public init(
        path: String,
        cachePolicy: FileReadCachePolicy = .system,
        openNonblocking: Bool = false
    ) throws {
        let descriptor = path.withCString { pointer in
            systemOpenReadOnly(
                pointer,
                flags: openNonblocking ? O_NONBLOCK : 0
            )
        }

        guard descriptor >= 0 else {
            throw SystemFileSourceError.open(
                path: path,
                code: errno
            )
        }

        let cacheCode = systemConfigureReadCache(
            descriptor,
            policy: cachePolicy
        )

        guard cacheCode == 0 else {
            _ = systemClose(
                descriptor
            )
            throw SystemFileSourceError.cache(
                path: path,
                code: cacheCode
            )
        }

        self.path = path
        self.descriptor = descriptor
    }

    deinit {
        if descriptor >= 0 {
            _ = systemClose(
                descriptor
            )
        }
    }

    /// Metadata of the opened file (`fstat`): exactly the object `refill` reads,
    /// even if `path` has since been replaced or was a symlink. `url` labels the
    /// snapshot; it defaults to `path`.
    public borrowing func inspect(
        url: URL? = nil
    ) throws -> FileMetadataSnapshot {
        guard descriptor >= 0 else {
            throw SystemFileSourceError.closed(
                path: path
            )
        }

        var info = stat()

        guard fstat(descriptor, &info) == 0 else {
            throw SystemFileSourceError.inspect(
                path: path,
                code: errno
            )
        }

        return NativeFileSystem.snapshot(
            url: url ?? URL(fileURLWithPath: path),
            info: info
        )
    }

    public mutating func refill(
        into bytes: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        guard descriptor >= 0 else {
            throw SystemFileSourceError.closed(
                path: path
            )
        }

        guard !bytes.isEmpty else {
            return .unavailable
        }

        let result = systemRead(
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
            return .end
        }

        let code = errno

        if code == EINTR {
            return .retry
        }

        if code == EAGAIN || code == EWOULDBLOCK {
            return .unavailable
        }

        throw SystemFileSourceError.read(
            path: path,
            code: code
        )
    }

    public mutating func close() throws {
        guard descriptor >= 0 else {
            return
        }

        let openDescriptor = descriptor
        descriptor = -1

        guard systemClose(openDescriptor) == 0 else {
            throw SystemFileSourceError.close(
                path: path,
                code: errno
            )
        }
    }
}

@inline(__always)
private func systemOpenReadOnly(
    _ path: UnsafePointer<CChar>,
    flags: Int32
) -> Int32 {
    while true {
        #if canImport(Darwin)
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | flags)
        #elseif canImport(Glibc)
        let descriptor = Glibc.open(path, O_RDONLY | O_CLOEXEC | flags)
        #endif

        if descriptor >= 0 || errno != EINTR {
            return descriptor
        }
    }
}

@inline(__always)
private func systemConfigureReadCache(
    _ descriptor: Int32,
    policy: FileReadCachePolicy
) -> Int32 {
    switch policy {
    case .system:
        return 0

    case .uncached:
        #if canImport(Darwin)
        guard Darwin.fcntl(
            descriptor,
            F_NOCACHE,
            1
        ) == 0 else {
            return errno
        }
        return 0
        #elseif canImport(Glibc)
        return Int32(
            Glibc.posix_fadvise(
                descriptor,
                0,
                0,
                POSIX_FADV_NOREUSE
            )
        )
        #endif
    }
}

@inline(__always)
private func systemRead(
    _ descriptor: Int32,
    _ buffer: UnsafeMutableRawPointer?,
    _ count: Int
) -> Int {
    #if canImport(Darwin)
    Darwin.read(descriptor, buffer, count)
    #elseif canImport(Glibc)
    Glibc.read(descriptor, buffer, count)
    #endif
}

@inline(__always)
private func systemClose(
    _ descriptor: Int32
) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(descriptor)
    #elseif canImport(Glibc)
    Glibc.close(descriptor)
    #endif
}
