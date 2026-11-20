import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public extension FileSystem {
    /// The process's working directory: one `getcwd`. Throws when it can't be read (deleted
    /// under the process, or a component lost its search permission).
    static func cwd() throws -> URL {
        guard let path = getcwd(nil, 0) else {
            throw FileSystemError(operation: .inspect, url: URL(fileURLWithPath: "."), errno: errno)
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
}
