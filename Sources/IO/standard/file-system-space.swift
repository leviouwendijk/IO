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
        /// The allocation unit (`f_bsize`): every file takes whole blocks.
        public let blockSize: Int64
        /// The largest regular file the volume can hold, from
        /// `pathconf(_PC_FILESIZEBITS)`: 2³² − 1 on FAT32. nil when the volume
        /// does not say.
        public let maxFileSize: Int64?
        /// Identifies the volume (`f_fsid`): equal for paths on one volume.
        public let identifier: UInt64

        public init(
            available: Int64,
            total: Int64,
            blockSize: Int64,
            maxFileSize: Int64?,
            identifier: UInt64
        ) {
            self.available = available
            self.total = total
            self.blockSize = blockSize
            self.maxFileSize = maxFileSize
            self.identifier = identifier
        }
    }

    /// What a tree would take when written to a volume, from one walk.
    struct Footprint: Sendable, Equatable {
        /// Logical bytes of the regular files and symbolic links.
        public let bytes: Int64
        /// Each file rounded up to the block size, plus one block per directory.
        public let allocated: Int64
        /// The largest single regular file.
        public let largestFile: Int64
        /// Regular files and symbolic links.
        public let files: Int

        public init(bytes: Int64, allocated: Int64, largestFile: Int64, files: Int) {
            self.bytes = bytes
            self.allocated = allocated
            self.largestFile = largestFile
            self.files = files
        }
    }

    /// The volume holding `url`: one `statfs` and one `pathconf`.
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
            total: Int64(clamping: info.f_blocks) * blockSize,
            blockSize: blockSize,
            maxFileSize: Self.maxFileSize(url.path),
            identifier: Self.volumeIdentifier(info)
        )
    }

    /// `FILESIZEBITS` counts the sign bit, so b bits hold files up to 2^(b−1) − 1.
    private static func maxFileSize(
        _ path: String
    ) -> Int64? {
        errno = 0
        let bits = pathconf(path, Int32(_PC_FILESIZEBITS))
        guard bits > 0 else {
            return nil
        }
        guard bits < 64 else {
            return Int64.max
        }
        return (Int64(1) << (Int64(bits) - 1)) - 1
    }

    private static func volumeIdentifier(
        _ info: statfs
    ) -> UInt64 {
        #if canImport(Darwin)
        let (high, low) = (info.f_fsid.val.0, info.f_fsid.val.1)
        #else
        let (high, low) = (info.f_fsid.__val.0, info.f_fsid.__val.1)
        #endif
        return UInt64(UInt32(bitPattern: high)) << 32 | UInt64(UInt32(bitPattern: low))
    }

    /// What `url` and everything below it would take on a volume with
    /// `blockSize`. One physical `fts` walk with the same rules as `size(of:)`:
    /// links counted, not followed; mount points not crossed; each hard-linked
    /// inode once; vanished entries skipped; a missing `url` throws.
    func footprint(
        of url: URL,
        rounding blockSize: Int64
    ) throws -> Footprint {
        let block = max(blockSize, 1)
        var bytes: Int64 = 0
        var allocated: Int64 = 0
        var largest: Int64 = 0
        var files = 0

        try walk(url) { stat in
            let kind = stat.st_mode & S_IFMT
            guard kind != S_IFDIR else {
                allocated += block
                return
            }
            let size = Int64(stat.st_size)
            bytes += size
            allocated += (size + block - 1) / block * block
            files += 1
            if kind == S_IFREG {
                largest = max(largest, size)
            }
        }
        return .init(bytes: bytes, allocated: allocated, largestFile: largest, files: files)
    }

    /// Bytes allocated on disk for `url` and everything below it (`st_blocks × 512`), counting
    /// each hard-linked inode once. One physical `fts` walk: symbolic links are counted, not
    /// followed, and mount points below `url` are not crossed. Entries that vanish or can't be
    /// read during the walk are skipped; a missing `url` throws.
    func size(
        of url: URL
    ) throws -> Int64 {
        var total: Int64 = 0
        try walk(url) { stat in
            total += Int64(stat.st_blocks) * 512
        }
        return total
    }

    /// One physical `fts` walk over `url`, visiting each entry's `stat` once
    /// (hard-linked inodes once, directories in preorder).
    private func walk(
        _ input: URL,
        _ visit: (stat) -> Void
    ) throws {
        let url = input.standardizedFileURL
        guard let path = strdup(url.path) else {
            throw FileSystemError(operation: .inspect, url: url, errno: ENOMEM)
        }
        defer { free(path) }

        var arguments: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let tree = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw FileSystemError(operation: .inspect, url: url, errno: errno)
        }
        defer { fts_close(tree) }

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
            visit(stat)
        }
    }
}

private struct LinkedInode: Hashable {
    let device: UInt64
    let inode: UInt64
}
