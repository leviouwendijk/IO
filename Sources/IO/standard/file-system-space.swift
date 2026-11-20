import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Disk space: what a volume has free, and what a tree occupies.
/// Neither is on a read/write hot path; both are one call or one walk.
public extension FileSystem {
    struct Volume: Sendable, Equatable {
        /// Bytes available to an unprivileged process (`f_bavail × f_bsize`).
        public let available: Int64
        public let total: Int64

        public init(available: Int64, total: Int64) {
            self.available = available
            self.total = total
        }
    }

    /// The volume holding `url`: one `statfs`.
    func volume(
        of url: URL
    ) throws -> Volume {
        let url = url.standardizedFileURL
        var info = statfs()
        guard statfs(url.path, &info) == 0 else {
            throw FileSystemError(operation: .inspect, url: url, errno: errno)
        }
        let blockSize = Int64(info.f_bsize)
        return .init(
            available: Int64(clamping: info.f_bavail) * blockSize,
            total: Int64(clamping: info.f_blocks) * blockSize
        )
    }

    /// Bytes allocated on disk for `url` and everything below it (`st_blocks × 512`), counting
    /// each hard-linked inode once. One physical `fts` walk: symbolic links are counted, not
    /// followed, and mount points below `url` are not crossed. Entries that vanish or can't be
    /// read during the walk are skipped; a missing `url` throws.
    func size(
        of url: URL
    ) throws -> Int64 {
        let url = url.standardizedFileURL
        guard let path = strdup(url.path) else {
            throw FileSystemError(operation: .inspect, url: url, errno: ENOMEM)
        }
        defer { free(path) }

        var arguments: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let tree = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw FileSystemError(operation: .inspect, url: url, errno: errno)
        }
        defer { fts_close(tree) }

        var total: Int64 = 0
        var linked = Set<LinkedInode>()

        while let entry = fts_read(tree) {
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_DP:
                continue

            case FTS_NS, FTS_ERR, FTS_DNR:
                if Int32(entry.pointee.fts_level) == FTS_ROOTLEVEL, info != FTS_DNR {
                    throw FileSystemError(operation: .inspect, url: url, errno: entry.pointee.fts_errno)
                }
                if info == FTS_NS { continue }

            default:
                break
            }

            guard let stat = entry.pointee.fts_statp?.pointee else { continue }
            if stat.st_nlink > 1, (stat.st_mode & S_IFMT) != S_IFDIR {
                guard linked.insert(.init(device: UInt64(stat.st_dev), inode: UInt64(stat.st_ino))).inserted else {
                    continue
                }
            }
            total += Int64(stat.st_blocks) * 512
        }
        return total
    }
}

private struct LinkedInode: Hashable {
    let device: UInt64
    let inode: UInt64
}
