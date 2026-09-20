import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct FileSystemError:
    Error,
    Sendable,
    Hashable,
    LocalizedError
{
    public enum Operation:
        String,
        Sendable,
        Hashable,
        Codable
    {
        case inspect
        case enumerate_directory
        case inspect_directory_entry
        case probe_directory_empty
    }

    public enum Reason:
        String,
        Sendable,
        Hashable,
        Codable
    {
        case not_found
        case permission_denied
        case not_directory
        case symbolic_link_loop
        case name_too_long
        case process_file_limit
        case system_file_limit
        case io
        case invalid_argument
        case unknown
    }

    public let operation: Operation
    public let url: URL
    public let errno: Int32
    public let reason: Reason

    public init(
        operation: Operation,
        url: URL,
        errno: Int32
    ) {
        self.operation = operation
        self.url = url.standardizedFileURL
        self.errno = errno
        self.reason = Self.reason(
            for: errno
        )
    }

    public var errorDescription: String? {
        "Filesystem \(operation.rawValue) failed for \(url.path): "
            + "\(reason.rawValue) (errno \(errno))"
    }
}

extension FileSystemError {
    static func wrapping(
        _ error: Error,
        operation: Operation,
        url: URL
    ) -> Self? {
        if let error = error as? Self {
            return error
        }

        guard let code = posixErrno(
            from: error as NSError
        ) else {
            return nil
        }

        return .init(
            operation: operation,
            url: url,
            errno: code
        )
    }
}

private extension FileSystemError {
    static func reason(
        for code: Int32
    ) -> Reason {
        switch code {
        case ENOENT:
            return .not_found
        case EACCES, EPERM:
            return .permission_denied
        case ENOTDIR:
            return .not_directory
        case ELOOP:
            return .symbolic_link_loop
        case ENAMETOOLONG:
            return .name_too_long
        case EMFILE:
            return .process_file_limit
        case ENFILE:
            return .system_file_limit
        case EIO:
            return .io
        case EINVAL:
            return .invalid_argument
        default:
            return .unknown
        }
    }

    static func posixErrno(
        from error: NSError
    ) -> Int32? {
        if error.domain == NSPOSIXErrorDomain {
            return Int32(
                clamping: error.code
            )
        }

        if
            let underlying = error.userInfo[
                NSUnderlyingErrorKey
            ] as? NSError,
            let code = posixErrno(
                from: underlying
            )
        {
            return code
        }

        guard error.domain == NSCocoaErrorDomain else {
            return nil
        }

        switch error.code {
        case CocoaError.Code.fileNoSuchFile.rawValue,
             CocoaError.Code.fileReadNoSuchFile.rawValue:
            return ENOENT

        case CocoaError.Code.fileReadNoPermission.rawValue,
             CocoaError.Code.fileWriteNoPermission.rawValue:
            return EACCES

        default:
            return nil
        }
    }
}
