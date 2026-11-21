import Foundation

public extension FileSystem {
    /// Marks `url` so Time Machine skips it and everything below it: the
    /// sticky flag `tmutil addexclusion` sets (an extended attribute, one
    /// `setxattr`). For caches outside `~/Library/Caches`, which backups
    /// already skip. A no-op off macOS.
    func excludeFromBackup(
        _ url: URL
    ) throws {
        #if os(macOS)
        var url = url.standardizedFileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(
            values
        )
        #endif
    }
}
