#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum SystemFileSourceError: Error, Sendable, Equatable {
    case open(path: String, code: Int32)
    case cache(path: String, code: Int32)
    case read(path: String, code: Int32)
    case close(path: String, code: Int32)
    case closed(path: String)
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

    public init(
        path: String,
        cachePolicy: FileReadCachePolicy = .system
    ) throws {
        let descriptor = path.withCString { pointer in
            systemOpenReadOnly(pointer)
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
            bytes.count
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

        if errno == EINTR {
            return .retry
        }

        throw SystemFileSourceError.read(
            path: path,
            code: errno
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
    _ path: UnsafePointer<CChar>
) -> Int32 {
    #if canImport(Darwin)
    Darwin.open(path, O_RDONLY)
    #elseif canImport(Glibc)
    Glibc.open(path, O_RDONLY)
    #endif
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
