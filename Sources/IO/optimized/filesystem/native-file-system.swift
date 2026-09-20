import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum NativeFileSystem {
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return url.standardizedFileURL.path.withCString {
            stat($0, &info)
        } == 0
    }

    static func inspect(_ input: URL) throws -> FileMetadataSnapshot {
        let url = input.standardizedFileURL
        var info = stat()

        guard url.path.withCString({ lstat($0, &info) }) == 0 else {
            let code = errno

            if code == ENOENT || code == ENOTDIR {
                return .init(
                    url: url,
                    existed: false,
                    byteCount: nil,
                    modifiedAt: nil,
                    identity: nil,
                    kind: nil
                )
            }

            throw FileSystemError(
                operation: .inspect,
                url: url,
                errno: code
            )
        }

        return .init(
            url: url,
            existed: true,
            byteCount: Int(info.st_size),
            modifiedAt: modifiedAt(info),
            identity: .init(
                deviceID: UInt64(info.st_dev),
                fileID: UInt64(info.st_ino)
            ),
            kind: kind(mode: info.st_mode)
        )
    }

    static func entries(
        _ input: URL,
        options: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [FileSystemEntry] {
        try nativeEntries(
            input,
            options: options
        ).materializedFileSystemEntries()
    }

    static func recursiveEntries(
        _ input: URL,
        options: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [FileSystemEntry] {
        let batches = try recursiveNativeEntries(
            input,
            options: options
        )
        let entryCount = batches.reduce(
            into: 0
        ) {
            $0 += $1.count
        }

        var result: [FileSystemEntry] = []
        result.reserveCapacity(entryCount)

        for batch in batches {
            batch.appendMaterializedFileSystemEntries(
                to: &result
            )
        }

        return result
    }

    static func nativeEntries(
        _ input: URL,
        options: FileManager.DirectoryEnumerationOptions = []
    ) throws -> NativeDirectoryEntries {
        let url = input.standardizedFileURL

        guard let parent = NativePath(
            fileSystemURL: url
        ) else {
            throw FileSystemError(
                operation: .enumerate_directory,
                url: url,
                errno: EINVAL
            )
        }

        return try nativeEntries(
            parent,
            diagnosticURL: url,
            options: options
        )
    }

    static func recursiveNativeEntries(
        _ input: URL,
        options: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [NativeDirectoryEntries] {
        let url = input.standardizedFileURL

        guard let root = NativePath(
            fileSystemURL: url
        ) else {
            throw FileSystemError(
                operation: .enumerate_directory,
                url: url,
                errno: EINVAL
            )
        }

        var result: [NativeDirectoryEntries] = []

        try appendRecursiveNativeEntries(
            root,
            diagnosticURL: url,
            options: options,
            to: &result
        )

        return result
    }

    static func nativeEntries(
        _ parent: NativePath,
        diagnosticURL: URL? = nil,
        options: FileManager.DirectoryEnumerationOptions = []
    ) throws -> NativeDirectoryEntries {
        guard let directory = parent.withCString({
            opendir($0)
        }) else {
            throw FileSystemError(
                operation: .enumerate_directory,
                url: diagnosticURL
                    ?? parent.fileSystemURL(
                        isDirectory: true
                    ),
                errno: errno
            )
        }

        defer {
            closedir(directory)
        }

        let descriptor = dirfd(directory)
        var result = NativeDirectoryEntries.Builder(
            parent: parent
        )

        while true {
            errno = 0

            guard let pointer = readdir(directory) else {
                let code = errno

                if code != 0 {
                    throw FileSystemError(
                        operation: .enumerate_directory,
                        url: parent.fileSystemURL(
                            isDirectory: true
                        ),
                        errno: code
                    )
                }

                break
            }

            let name = directoryEntryName(pointer)

            if name == "." || name == ".." {
                continue
            }

            if options.contains(.skipsHiddenFiles),
               name.hasPrefix(".")
            {
                continue
            }

            guard let kind = try kind(
                directoryEntryType: Int32(
                    pointer.pointee.d_type
                ),
                directoryDescriptor: descriptor,
                name: name,
                parent: parent
            ) else {
                continue
            }

            let isDirectoryPath = isDirectoryPath(
                for: kind,
                directoryDescriptor: descriptor,
                name: name
            )

            withDirectoryEntryNameBytes(
                pointer
            ) {
                result.appendTrustedFileSystemComponent(
                    $0,
                    kind: kind,
                    isDirectoryPath: isDirectoryPath
                )
            }
        }

        return result.build()
    }

    static func appendRecursiveNativeEntries(
        _ parent: NativePath,
        diagnosticURL: URL? = nil,
        options: FileManager.DirectoryEnumerationOptions,
        to result: inout [NativeDirectoryEntries]
    ) throws {
        let direct = try nativeEntries(
            parent,
            diagnosticURL: diagnosticURL,
            options: options
        )

        result.append(direct)

        for entry in direct.entries
        where entry.kind == .directory
        {
            try appendRecursiveNativeEntries(
                direct.path(
                    for: entry
                ),
                options: options,
                to: &result
            )
        }
    }

    static func isEmpty(_ input: URL) throws -> Bool {
        let url = input.standardizedFileURL

        guard let directory = url.path.withCString({ opendir($0) }) else {
            throw FileSystemError(
                operation: .probe_directory_empty,
                url: url,
                errno: errno
            )
        }

        defer {
            closedir(directory)
        }

        while true {
            errno = 0

            guard let pointer = readdir(directory) else {
                let code = errno

                if code != 0 {
                    throw FileSystemError(
                        operation: .probe_directory_empty,
                        url: url,
                        errno: code
                    )
                }

                return true
            }

            let name = directoryEntryName(pointer)

            if name != "." && name != ".." {
                return false
            }
        }
    }
}

private extension NativeFileSystem {
    static func kind(
        directoryEntryType: Int32,
        directoryDescriptor: Int32,
        name: String,
        parent: NativePath
    ) throws -> FileKind? {
        switch directoryEntryType {
        case Int32(DT_REG):
            return .file
        case Int32(DT_DIR):
            return .directory
        case Int32(DT_LNK):
            return .symlink
        case Int32(DT_UNKNOWN):
            return try fallbackKind(
                directoryDescriptor: directoryDescriptor,
                name: name,
                parent: parent
            )
        default:
            return .other
        }
    }

    static func fallbackKind(
        directoryDescriptor: Int32,
        name: String,
        parent: NativePath
    ) throws -> FileKind? {
        var info = stat()
        let result = name.withCString {
            fstatat(
                directoryDescriptor,
                $0,
                &info,
                AT_SYMLINK_NOFOLLOW
            )
        }

        guard result == 0 else {
            let code = errno

            if code == ENOENT {
                return nil
            }

            throw FileSystemError(
                operation: .inspect_directory_entry,
                url: parent
                    .fileSystemURL(
                        isDirectory: true
                    )
                    .appending(
                        component: name,
                        directoryHint: .inferFromPath
                    ),
                errno: code
            )
        }

        return kind(mode: info.st_mode)
    }

    static func isDirectoryPath(
        for entryKind: FileKind,
        directoryDescriptor: Int32,
        name: String
    ) -> Bool {
        switch entryKind {
        case .directory:
            return true

        case .symlink:
            // d_type/lstat describes the link itself. Follow only
            // this symlink to preserve directory-path semantics
            // without re-probing ordinary entries.
            var target = stat()
            let result = name.withCString {
                fstatat(
                    directoryDescriptor,
                    $0,
                    &target,
                    0
                )
            }

            guard result == 0 else {
                return false
            }

            return kind(
                mode: target.st_mode
            ) == .directory

        case .file, .other:
            return false
        }
    }

    static func kind(mode: mode_t) -> FileKind {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG):
            return .file
        case mode_t(S_IFDIR):
            return .directory
        case mode_t(S_IFLNK):
            return .symlink
        default:
            return .other
        }
    }

    static func directoryEntryName(
        _ pointer: UnsafeMutablePointer<dirent>
    ) -> String {
        withDirectoryEntryNameBytes(
            pointer
        ) {
            String(
                decoding: $0,
                as: UTF8.self
            )
        }
    }

    static func withDirectoryEntryNameBytes<Result>(
        _ pointer: UnsafeMutablePointer<dirent>,
        body: (UnsafeBufferPointer<UInt8>) -> Result
    ) -> Result {
        let capacity = MemoryLayout.size(
            ofValue: pointer.pointee.d_name
        )

        return withUnsafePointer(
            to: &pointer.pointee.d_name
        ) {
            $0.withMemoryRebound(
                to: UInt8.self,
                capacity: capacity
            ) { bytes in
                #if canImport(Darwin)
                let length = Int(
                    pointer.pointee.d_namlen
                )
                #else
                var length = 0
                while length < capacity,
                      bytes[length] != 0
                {
                    length += 1
                }
                #endif

                return body(
                    UnsafeBufferPointer(
                        start: bytes,
                        count: length
                    )
                )
            }
        }
    }

    static func modifiedAt(_ value: stat) -> Date {
        #if canImport(Darwin)
        let seconds = value.st_mtimespec.tv_sec
        let nanoseconds = value.st_mtimespec.tv_nsec
        #else
        let seconds = value.st_mtim.tv_sec
        let nanoseconds = value.st_mtim.tv_nsec
        #endif

        return Date(
            timeIntervalSince1970:
                Double(seconds)
                + Double(nanoseconds) / 1_000_000_000
        )
    }

}
