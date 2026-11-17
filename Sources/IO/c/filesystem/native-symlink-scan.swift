import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A symbolic link met while walking a path.
public struct FileSymlink: Sendable, Hashable {
    /// The link itself.
    public let url: URL
    /// The target as stored in the link (`readlink`).
    public let target: String

    public init(
        url: URL,
        target: String
    ) {
        self.url = url
        self.target = target
    }

    /// The target as an absolute, lexically normalized URL: a relative
    /// target is taken from the link's directory.
    public var destination: URL {
        if target.hasPrefix("/") {
            return URL(
                fileURLWithPath: target
            ).standardizedFileURL
        }

        return url
            .deletingLastPathComponent()
            .appendingPathComponent(
                target
            )
            .standardizedFileURL
    }
}

/// Finds the first symlink among a path's components below a trusted base.
///
/// Darwin: one `fstatat(AT_SYMLINK_NOFOLLOW_ANY)` answers the common case
/// (no link anywhere in the path, or the walk ends at a missing component
/// before meeting one). Only `ELOOP` (a link somewhere, possibly in the
/// base itself, e.g. `/var`) or another error falls back to a `readlink`
/// per component below the base. Linux always walks.
enum NativeSymlinkScan {
    static func first(
        in url: URL,
        below base: URL
    ) throws -> FileSymlink? {
        let path = url.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        let prefix = basePath == "/"
            ? "/"
            : basePath + "/"

        guard path == basePath || path.hasPrefix(prefix) else {
            throw FileSystemError(
                operation: .inspect,
                url: url,
                errno: EINVAL
            )
        }

        guard path != basePath else {
            return nil
        }

        #if canImport(Darwin)
        var info = stat()
        let code: Int32 = path.withCString {
            fstatat(
                AT_FDCWD,
                $0,
                &info,
                AT_SYMLINK_NOFOLLOW_ANY
            ) == 0 ? 0 : errno
        }

        // A link before a missing component would have been met first and
        // reported as ELOOP.
        if code == 0 || code == ENOENT || code == ENOTDIR {
            return nil
        }
        #endif

        var current = basePath == "/" ? "" : basePath

        for component in path.dropFirst(prefix.count).split(separator: "/") {
            current += "/" + component

            let read: (count: Int, code: Int32, target: String) = withUnsafeTemporaryAllocation(
                of: CChar.self,
                capacity: Int(PATH_MAX)
            ) { buffer in
                guard let pointer = buffer.baseAddress else {
                    return (-1, ENOMEM, "")
                }

                let (count, code): (Int, Int32) = current.withCString {
                    let count = readlink(
                        $0,
                        pointer,
                        buffer.count - 1
                    )
                    return (count, count < 0 ? errno : 0)
                }

                guard count >= 0 else {
                    return (-1, code, "")
                }

                pointer[count] = 0

                return (count, 0, String(cString: pointer))
            }

            if read.count >= 0 {
                return FileSymlink(
                    url: URL(
                        fileURLWithPath: current
                    ),
                    target: read.target
                )
            }

            switch read.code {
            case EINVAL:
                // Not a link.
                continue

            case ENOENT, ENOTDIR:
                // Nothing exists below this component.
                return nil

            default:
                throw FileSystemError(
                    operation: .inspect,
                    url: URL(
                        fileURLWithPath: current
                    ),
                    errno: read.code
                )
            }
        }

        return nil
    }
}
