import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin)
private struct NativeCapturedExtendedACL {
    let value: acl_t?
}
#endif

/// Native filesystem mutation paths selected by semantic characterization and
/// benchmark convergence.
///
/// Current native paths include:
///
/// - directory creation without Foundation attributes;
/// - file/symlink and recursive directory removal;
/// - same-filesystem no-replace rename;
/// - Darwin regular-file replacement with selective preservation of the
///   original POSIX mode, creation time, and extended ACL;
/// - Darwin regular-file copy through atomic clonefile with ACL preservation;
/// - Darwin recursive directory copy through retained directory descriptors,
///   clonefileat leaves, and postorder directory metadata finalization.
///
/// Non-regular copy, clone-unavailable copy, cross-device move, non-regular
/// replacement, unsupported metadata cases, and Foundation's attribute
/// dictionary retain compatibility fallbacks.
enum NativeFileSystemMutation {
    static func createDirectory(
        _ input: URL,
        intermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws {
        guard attributes == nil else {
            let url =
                input.standardizedFileURL

            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories:
                    intermediates,
                attributes: attributes
            )
            return
        }

        try input.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                let url =
                    input.standardizedFileURL

                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories:
                        intermediates,
                    attributes: nil
                )
                return
            }

            if containsLexicalDotComponent(
                pointer
            ) {
                let url =
                    input.standardizedFileURL

                try url.withUnsafeFileSystemRepresentation {
                    standardizedPointer in

                    guard let standardizedPointer else {
                        try FileManager.default.createDirectory(
                            at: url,
                            withIntermediateDirectories:
                                intermediates,
                            attributes: nil
                        )
                        return
                    }

                    try createDirectory(
                        standardizedPointer,
                        url: url,
                        intermediates:
                            intermediates
                    )
                }
                return
            }

            try createDirectory(
                pointer,
                url: input,
                intermediates:
                    intermediates
            )
        }
    }
    static func copy(
        _ sourceInput: URL,
        to destinationInput: URL
    ) throws {
        #if canImport(Darwin)
        if try copyDarwin(
            sourceInput,
            to: destinationInput
        ) {
            return
        }
        #endif

        try FileManager.default.copyItem(
            at: sourceInput.standardizedFileURL,
            to: destinationInput.standardizedFileURL
        )
    }

    static func replace(
        _ originalInput: URL,
        with replacementInput: URL
    ) throws {
        #if canImport(Darwin)
        let original =
            mutationURL(
                originalInput
            )
        let replacement =
            mutationURL(
                replacementInput
            )

        if try replaceRegularFileDarwin(
            original,
            with: replacement
        ) {
            return
        }
        #endif

        _ = try FileManager.default.replaceItemAt(
            originalInput.standardizedFileURL,
            withItemAt:
                replacementInput.standardizedFileURL
        )
    }

    static func remove(
        _ input: URL
    ) throws {
        let url =
            mutationURL(
                input
            )

        try url.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                try FileManager.default.removeItem(
                    at: url
                )
                return
            }

            if systemUnlink(
                pointer
            ) == 0 {
                return
            }

            let unlinkCode =
                errno

            guard unlinkCode == EISDIR
                    || unlinkCode == EPERM
            else {
                throw FileSystemError(
                    operation: .remove,
                    url: url,
                    errno: unlinkCode
                )
            }

            if systemRmdir(
                pointer
            ) == 0 {
                return
            }

            let rmdirCode =
                errno

            // A non-directory regular entry can report EPERM from unlink.
            // Let rmdir distinguish that case without paying an lstat on the
            // normal directory path, but preserve the original unlink error.
            if rmdirCode == ENOTDIR {
                throw FileSystemError(
                    operation: .remove,
                    url: url,
                    errno: unlinkCode
                )
            }

            guard rmdirCode == ENOTEMPTY
                    || rmdirCode == EEXIST
            else {
                throw FileSystemError(
                    operation: .remove,
                    url: url,
                    errno: rmdirCode
                )
            }

            try removeDirectoryTree(
                pointer,
                url: url
            )
        }
    }
    static func move(
        _ sourceInput: URL,
        to destinationInput: URL
    ) throws {
        let source =
            mutationURL(
                sourceInput
            )
        let destination =
            mutationURL(
                destinationInput
            )

        try source.withUnsafeFileSystemRepresentation {
            sourcePointer in

            try destination
                .withUnsafeFileSystemRepresentation {
                    destinationPointer in

                    guard let sourcePointer,
                          let destinationPointer
                    else {
                        try FileManager.default.moveItem(
                            at: source,
                            to: destination
                        )
                        return
                    }

                    if strcmp(
                        sourcePointer,
                        destinationPointer
                    ) == 0 {
                        var sourceInfo =
                            stat()

                        guard systemLstat(
                            sourcePointer,
                            &sourceInfo
                        ) == 0 else {
                            throw FileSystemError(
                                operation: .move,
                                url: source,
                                errno: errno
                            )
                        }

                        return
                    }

                    let result =
                        systemRenameNoReplace(
                            sourcePointer,
                            destinationPointer
                        )

                    if result == 0 {
                        return
                    }

                    let code =
                        errno

                    if code == EXDEV {
                        try FileManager.default.moveItem(
                            at: source,
                            to: destination
                        )
                        return
                    }

                    throw FileSystemError(
                        operation: .move,
                        url: source,
                        errno: code
                    )
                }
        }
    }
}

private extension NativeFileSystemMutation {
    #if canImport(Darwin)
    static func copyDarwin(
        _ source: URL,
        to destination: URL
    ) throws -> Bool {
        try source.withUnsafeFileSystemRepresentation {
            sourcePointer in

            guard let sourcePointer,
                  !containsLexicalDotComponent(
                    sourcePointer
                  )
            else {
                return false
            }

            var sourceInfo = stat()
            guard Darwin.lstat(
                sourcePointer,
                &sourceInfo
            ) == 0 else {
                return false
            }

            let sourceKind =
                sourceInfo.st_mode
                & mode_t(
                    S_IFMT
                )

            return try destination.withUnsafeFileSystemRepresentation {
                destinationPointer in

                guard let destinationPointer,
                      !containsLexicalDotComponent(
                        destinationPointer
                      )
                else {
                    return false
                }

                if sourceKind
                    == mode_t(
                        S_IFREG
                    )
                {
                    return Darwin.clonefile(
                        sourcePointer,
                        destinationPointer,
                        UInt32(CLONE_ACL)
                            | UInt32(CLONE_NOFOLLOW)
                    ) == 0
                }

                guard sourceKind
                        == mode_t(
                            S_IFDIR
                        )
                else {
                    return false
                }

                return try copyDirectoryTreeDarwin(
                    sourcePointer: sourcePointer,
                    destinationPointer:
                        destinationPointer,
                    source: source,
                    destination: destination
                )
            }
        }
    }

    /// Copies a directory tree through retained directory descriptors.
    ///
    /// Once the destination root has been created, this native attempt owns
    /// that namespace. Any later failure must remove the partial tree before
    /// Foundation fallback is allowed. A rollback failure is surfaced instead.
    static func copyDirectoryTreeDarwin(
        sourcePointer:
            UnsafePointer<CChar>,
        destinationPointer:
            UnsafePointer<CChar>,
        source: URL,
        destination: URL
    ) throws -> Bool {
        var destinationInfo =
            stat()

        if Darwin.lstat(
            destinationPointer,
            &destinationInfo
        ) == 0 {
            return false
        }

        guard errno == ENOENT else {
            return false
        }

        let sourceDescriptor =
            systemOpenDirectoryAt(
                AT_FDCWD,
                sourcePointer
            )

        guard sourceDescriptor >= 0 else {
            return false
        }

        guard Darwin.mkdirat(
            AT_FDCWD,
            destinationPointer,
            mode_t(
                0o700
            )
        ) == 0 else {
            _ = systemClose(
                sourceDescriptor
            )
            return false
        }

        let destinationDescriptor =
            systemOpenDirectoryAt(
                AT_FDCWD,
                destinationPointer
            )

        guard destinationDescriptor >= 0 else {
            _ = systemClose(
                sourceDescriptor
            )

            do {
                try remove(
                    destination
                )
            } catch {
                throw error
            }

            return false
        }

        do {
            try copyDirectoryContentsDarwin(
                sourceDescriptor:
                    sourceDescriptor,
                destinationDescriptor:
                    destinationDescriptor,
                source: source
            )

            _ = systemClose(
                destinationDescriptor
            )
            return true
        } catch {
            _ = systemClose(
                destinationDescriptor
            )

            do {
                try remove(
                    destination
                )
            } catch {
                throw error
            }

            return false
        }
    }

    /// Copies one already-open source directory into one already-open
    /// destination directory. Ownership of `sourceDescriptor` is consumed by
    /// `fdopendir`; `destinationDescriptor` remains owned by the caller.
    static func copyDirectoryContentsDarwin(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        source: URL
    ) throws {
        guard let directory =
                fdopendir(
                    sourceDescriptor
                )
        else {
            let code =
                errno
            _ = systemClose(
                sourceDescriptor
            )

            throw FileSystemError(
                operation: .copy,
                url: source,
                errno: code
            )
        }

        defer {
            closedir(
                directory
            )
        }

        let sourceParentDescriptor =
            dirfd(
                directory
            )

        guard sourceParentDescriptor >= 0 else {
            throw FileSystemError(
                operation: .copy,
                url: source,
                errno: errno
            )
        }

        while true {
            errno = 0

            guard let entry =
                    readdir(
                        directory
                    )
            else {
                let code =
                    errno

                if code != 0 {
                    throw FileSystemError(
                        operation: .copy,
                        url: source,
                        errno: code
                    )
                }

                break
            }

            try withDirectoryEntryNameCString(
                entry
            ) {
                name in

                if isDotDirectoryEntry(
                    name
                ) {
                    return
                }

                let entryType =
                    Int32(
                        entry.pointee.d_type
                    )

                if entryType
                    == Int32(
                        DT_DIR
                    )
                {
                    try copyChildDirectoryDarwin(
                        sourceParentDescriptor:
                            sourceParentDescriptor,
                        destinationParentDescriptor:
                            destinationDescriptor,
                        name: name,
                        source: source
                    )
                    return
                }

                if entryType
                    == Int32(
                        DT_UNKNOWN
                    )
                {
                    var entryInfo =
                        stat()

                    guard Darwin.fstatat(
                        sourceParentDescriptor,
                        name,
                        &entryInfo,
                        AT_SYMLINK_NOFOLLOW
                    ) == 0 else {
                        throw FileSystemError(
                            operation: .copy,
                            url: source,
                            errno: errno
                        )
                    }

                    if entryInfo.st_mode
                        & mode_t(
                            S_IFMT
                        )
                        == mode_t(
                            S_IFDIR
                        )
                    {
                        try copyChildDirectoryDarwin(
                            sourceParentDescriptor:
                                sourceParentDescriptor,
                            destinationParentDescriptor:
                                destinationDescriptor,
                            name: name,
                            source: source
                        )
                        return
                    }
                }

                guard Darwin.clonefileat(
                    sourceParentDescriptor,
                    name,
                    destinationDescriptor,
                    name,
                    UInt32(
                        CLONE_ACL
                    )
                        | UInt32(
                            CLONE_NOFOLLOW
                        )
                ) == 0 else {
                    throw FileSystemError(
                        operation: .copy,
                        url: source,
                        errno: errno
                    )
                }
            }
        }

        guard Darwin.fcopyfile(
            sourceParentDescriptor,
            destinationDescriptor,
            nil,
            copyfile_flags_t(
                COPYFILE_METADATA
            )
        ) == 0 else {
            throw FileSystemError(
                operation: .copy,
                url: source,
                errno: errno
            )
        }
    }

    static func copyChildDirectoryDarwin(
        sourceParentDescriptor: Int32,
        destinationParentDescriptor: Int32,
        name: UnsafePointer<CChar>,
        source: URL
    ) throws {
        guard Darwin.mkdirat(
            destinationParentDescriptor,
            name,
            mode_t(
                0o700
            )
        ) == 0 else {
            throw FileSystemError(
                operation: .copy,
                url: source,
                errno: errno
            )
        }

        let sourceDescriptor =
            systemOpenDirectoryAt(
                sourceParentDescriptor,
                name
            )

        guard sourceDescriptor >= 0 else {
            throw FileSystemError(
                operation: .copy,
                url: source,
                errno: errno
            )
        }

        let destinationDescriptor =
            systemOpenDirectoryAt(
                destinationParentDescriptor,
                name
            )

        guard destinationDescriptor >= 0 else {
            let code =
                errno
            _ = systemClose(
                sourceDescriptor
            )

            throw FileSystemError(
                operation: .copy,
                url: source,
                errno: code
            )
        }

        defer {
            _ = systemClose(
                destinationDescriptor
            )
        }

        try copyDirectoryContentsDarwin(
            sourceDescriptor:
                sourceDescriptor,
            destinationDescriptor:
                destinationDescriptor,
            source: source
        )
    }

    static func replaceRegularFileDarwin(
        _ original: URL,
        with replacement: URL
    ) throws -> Bool {
        try original.withUnsafeFileSystemRepresentation {
            originalPointer in

            guard let originalPointer else {
                return false
            }

            return try replacement.withUnsafeFileSystemRepresentation {
                replacementPointer in

                guard let replacementPointer else {
                    return false
                }

                var originalInfo =
                    stat()
                var replacementInfo =
                    stat()

                guard Darwin.lstat(
                    originalPointer,
                    &originalInfo
                ) == 0,
                      Darwin.lstat(
                        replacementPointer,
                        &replacementInfo
                      ) == 0
                else {
                    return false
                }

                let originalKind =
                    originalInfo.st_mode
                    & mode_t(
                        S_IFMT
                    )
                let replacementKind =
                    replacementInfo.st_mode
                    & mode_t(
                        S_IFMT
                    )

                guard originalKind
                        == mode_t(
                            S_IFREG
                        ),
                      replacementKind
                        == mode_t(
                            S_IFREG
                        )
                else {
                    return false
                }

                guard let originalACL =
                        captureExtendedACL(
                            originalPointer
                        )
                else {
                    return false
                }

                defer {
                    freeCapturedExtendedACL(
                        originalACL
                    )
                }

                guard let replacementACL =
                        captureExtendedACL(
                            replacementPointer
                        )
                else {
                    return false
                }

                defer {
                    freeCapturedExtendedACL(
                        replacementACL
                    )
                }

                // Give the replacement the original's mode, birth time, and ACL
                // while it is still at its own path. The swap then publishes it
                // at the original path with the final metadata already in place,
                // so no observer sees the original path with the replacement's
                // own (possibly wider) permissions.
                let metadataCode =
                    systemApplyReplaceMetadata(
                        replacementPointer,
                        info: originalInfo,
                        acl: originalACL,
                        currentACLKnownAbsent:
                            replacementACL.value
                                == nil
                    )

                guard metadataCode == 0 else {
                    let restoreCode =
                        systemApplyReplaceMetadata(
                            replacementPointer,
                            info: replacementInfo,
                            acl: replacementACL,
                            currentACLKnownAbsent:
                                false
                        )

                    guard restoreCode == 0 else {
                        throw FileSystemError(
                            operation: .replace,
                            url: original,
                            errno:
                                restoreCode
                        )
                    }

                    return false
                }

                guard systemRenameSwap(
                    replacementPointer,
                    originalPointer
                ) == 0 else {
                    let restoreCode =
                        systemApplyReplaceMetadata(
                            replacementPointer,
                            info: replacementInfo,
                            acl: replacementACL,
                            currentACLKnownAbsent:
                                false
                        )

                    guard restoreCode == 0 else {
                        throw FileSystemError(
                            operation: .replace,
                            url: original,
                            errno:
                                restoreCode
                        )
                    }

                    return false
                }

                guard Darwin.unlink(
                    replacementPointer
                ) == 0 else {
                    let rollbackCode =
                        rollbackDarwinReplace(
                            originalPointer:
                                originalPointer,
                            replacementPointer:
                                replacementPointer,
                            replacementInfo:
                                replacementInfo,
                            replacementACL:
                                replacementACL
                        )

                    guard rollbackCode == 0 else {
                        throw FileSystemError(
                            operation: .replace,
                            url: original,
                            errno:
                                rollbackCode
                        )
                    }

                    return false
                }

                return true
            }
        }
    }

    /// Captures a Darwin extended ACL without treating the ordinary
    /// no-extended-ACL state as an unsupported fast-path case.
    ///
    /// `lstat` has already proved the object exists. On Darwin/APFS an
    /// ACL_TYPE_EXTENDED query for a file with no extended ACL can return
    /// nil/ENOENT; represent that as a valid absent ACL. Other failures
    /// remain compatibility-fallback conditions.
    static func captureExtendedACL(
        _ pointer:
            UnsafePointer<CChar>
    ) -> NativeCapturedExtendedACL? {
        errno = 0

        if let value =
                acl_get_file(
                    pointer,
                    ACL_TYPE_EXTENDED
                )
        {
            return .init(
                value: value
            )
        }

        guard errno == ENOENT else {
            return nil
        }

        return .init(
            value: nil
        )
    }

    static func freeCapturedExtendedACL(
        _ captured:
            NativeCapturedExtendedACL
    ) {
        guard let value =
                captured.value
        else {
            return
        }

        _ = acl_free(
            UnsafeMutableRawPointer(
                value
            )
        )
    }

    /// Restores the replacement object's original metadata while it is at
    /// `originalPointer`, then swaps the two names back to their pre-operation
    /// locations. Returning zero means Foundation can safely be used as the
    /// compatibility path without observing a partially applied native replace.
    static func rollbackDarwinReplace(
        originalPointer:
            UnsafePointer<CChar>,
        replacementPointer:
            UnsafePointer<CChar>,
        replacementInfo: stat,
        replacementACL:
            NativeCapturedExtendedACL
    ) -> Int32 {
        let metadataCode =
            systemApplyReplaceMetadata(
                originalPointer,
                info: replacementInfo,
                acl: replacementACL,
                currentACLKnownAbsent:
                    false
            )

        guard systemRenameSwap(
            replacementPointer,
            originalPointer
        ) == 0 else {
            return errno
        }

        return metadataCode
    }
    #endif

    static func createDirectory(
        _ pointer: UnsafePointer<CChar>,
        url: URL,
        intermediates: Bool
    ) throws {
        if !intermediates {
            guard systemMkdir(
                pointer
            ) == 0 else {
                throw FileSystemError(
                    operation:
                        .create_directory,
                    url: url,
                    errno: errno
                )
            }
            return
        }

        #if canImport(Darwin)
        let code =
            systemMkpathAtCurrentWorkingDirectory(
                pointer
            )

        if code == 0
            || code == EEXIST
        {
            return
        }

        // mkpathat_np follows the mkpath family contract: return the
        // error code directly rather than publishing it through errno.
        throw FileSystemError(
            operation:
                .create_directory,
            url: url,
            errno: code
        )
        #elseif canImport(Glibc)
        if systemMkdir(
            pointer
        ) == 0 {
            return
        }

        let firstCode =
            errno

        if firstCode == EEXIST,
           systemPathIsDirectory(
            pointer
           )
        {
            return
        }

        guard firstCode == ENOENT else {
            throw FileSystemError(
                operation:
                    .create_directory,
                url: url,
                errno: firstCode
            )
        }

        try withUnsafeTemporaryAllocation(
            of: CChar.self,
            capacity: Int(
                PATH_MAX
            )
        ) {
            storage in

            guard copyCString(
                pointer,
                into: storage
            )
            else {
                throw FileSystemError(
                    operation:
                        .create_directory,
                    url: url,
                    errno: ENAMETOOLONG
                )
            }

            try ensureMissingParentAndCreate(
                storage,
                length:
                    cStringLength(
                        pointer
                    ),
                url: url
            )
        }
        #endif
    }

    static func ensureMissingParentAndCreate(
        _ storage:
            UnsafeMutableBufferPointer<CChar>,
        length: Int,
        url: URL
    ) throws {
        guard let baseAddress =
                storage.baseAddress,
              length > 1
        else {
            throw FileSystemError(
                operation:
                    .create_directory,
                url: url,
                errno: EINVAL
            )
        }

        var slashIndex =
            length - 1

        while slashIndex > 0,
              storage[
                slashIndex
              ] != CChar(47)
        {
            slashIndex -= 1
        }

        let parentLength =
            max(
                1,
                slashIndex
            )
        let saved =
            storage[
                parentLength
            ]

        storage[
            parentLength
        ] = 0

        do {
            try ensureDirectory(
                storage,
                length:
                    parentLength,
                url: url
            )
        } catch {
            storage[
                parentLength
            ] = saved
            throw error
        }

        storage[
            parentLength
        ] = saved

        guard systemMkdir(
            baseAddress
        ) == 0 else {
            let code =
                errno

            if code == EEXIST,
               systemPathIsDirectory(
                baseAddress
               )
            {
                return
            }

            throw FileSystemError(
                operation:
                    .create_directory,
                url: url,
                errno: code
            )
        }
    }

    static func removeDirectoryTree(
        _ pointer:
            UnsafePointer<CChar>,
        url: URL
    ) throws {
        let descriptor =
            systemOpenDirectoryAt(
                AT_FDCWD,
                pointer
            )

        guard descriptor >= 0 else {
            throw FileSystemError(
                operation: .remove,
                url: url,
                errno: errno
            )
        }

        try removeDirectoryContents(
            descriptor,
            url: url
        )

        guard systemUnlinkAt(
            AT_FDCWD,
            pointer,
            AT_REMOVEDIR
        ) == 0 else {
            throw FileSystemError(
                operation: .remove,
                url: url,
                errno: errno
            )
        }
    }

    /// Removes every entry from an already-open directory.
    ///
    /// Ownership of `descriptor` is consumed by this function. `fdopendir`
    /// transfers it to the directory stream on success; the explicit close
    /// covers only the fdopendir failure path.
    static func removeDirectoryContents(
        _ descriptor: Int32,
        url: URL,
        depth: Int = 0
    ) throws {
        guard let directory =
                fdopendir(
                    descriptor
                )
        else {
            let code =
                errno
            _ = systemClose(
                descriptor
            )

            throw FileSystemError(
                operation: .remove,
                url: url,
                errno: code
            )
        }

        defer {
            closedir(
                directory
            )
        }

        let parentDescriptor =
            dirfd(
                directory
            )

        guard parentDescriptor >= 0 else {
            throw FileSystemError(
                operation: .remove,
                url: url,
                errno: errno
            )
        }

        while true {
            errno = 0

            guard let entry =
                    readdir(
                        directory
                    )
            else {
                let code =
                    errno

                if code != 0 {
                    throw FileSystemError(
                        operation: .remove,
                        url: url,
                        errno: code
                    )
                }

                return
            }

            try withDirectoryEntryNameCString(
                entry
            ) {
                name in

                if isDotDirectoryEntry(
                    name
                ) {
                    return
                }

                let entryType =
                    Int32(
                        entry.pointee.d_type
                    )

                // readdir already gives us a cheap directory hint on the
                // filesystems that populate d_type. Avoid a guaranteed failed
                // unlinkat for those entries. DT_UNKNOWN and every known
                // non-directory kind retain the unlink-first path.
                if entryType == Int32(
                    DT_DIR
                ) {
                    try removeChildDirectory(
                        parentDescriptor:
                            parentDescriptor,
                        name: name,
                        url: url,
                        originalUnlinkCode: nil,
                        depth: depth
                    )
                    return
                }

                if systemUnlinkAt(
                    parentDescriptor,
                    name,
                    0
                ) == 0 {
                    return
                }

                let unlinkCode =
                    errno

                guard unlinkCode == EISDIR
                        || unlinkCode == EPERM
                else {
                    throw FileSystemError(
                        operation: .remove,
                        url: url,
                        errno: unlinkCode
                    )
                }

                // DT_UNKNOWN directories reach here after the namespace
                // operation identifies them. EPERM is also retained so a
                // non-directory permission failure can be preserved if
                // openat subsequently reports ENOTDIR.
                try removeChildDirectory(
                    parentDescriptor:
                        parentDescriptor,
                    name: name,
                    url: url,
                    originalUnlinkCode:
                        unlinkCode,
                    depth: depth
                )
            }
        }
    }

    static func removeChildDirectory(
        parentDescriptor: Int32,
        name: UnsafePointer<CChar>,
        url: URL,
        originalUnlinkCode: Int32?,
        depth: Int
    ) throws {
        let childDescriptor =
            systemOpenDirectoryAt(
                parentDescriptor,
                name
            )

        guard childDescriptor >= 0 else {
            let openCode =
                errno

            if openCode == ENOTDIR
                || openCode == ELOOP
            {
                // A d_type hint may become stale if the entry changes between
                // readdir and openat. Never follow a replacement symlink:
                // O_NOFOLLOW rejects it, then unlink the leaf itself.
                if systemUnlinkAt(
                    parentDescriptor,
                    name,
                    0
                ) == 0 {
                    return
                }

                let retryCode =
                    errno

                if retryCode == ENOTDIR,
                   let originalUnlinkCode
                {
                    throw FileSystemError(
                        operation: .remove,
                        url: url,
                        errno:
                            originalUnlinkCode
                    )
                }

                throw FileSystemError(
                    operation: .remove,
                    url: url,
                    errno: retryCode
                )
            }

            throw FileSystemError(
                operation: .remove,
                url: url,
                errno:
                    openCode
            )
        }

        // Past the budget, switch to the walker that holds one directory
        // descriptor regardless of depth, so deep trees cannot exhaust the
        // process descriptor limit.
        if depth + 1 >= recursiveRemovalDescriptorBudget {
            try removeDirectoryContentsBounded(
                childDescriptor,
                url: url
            )
        } else {
            try removeDirectoryContents(
                childDescriptor,
                url: url,
                depth: depth + 1
            )
        }

        guard systemUnlinkAt(
            parentDescriptor,
            name,
            AT_REMOVEDIR
        ) == 0 else {
            throw FileSystemError(
                operation: .remove,
                url: url,
                errno: errno
            )
        }
    }

    /// Directories this many levels below the removal root are emptied by
    /// `removeDirectoryContentsBounded`, so recursive removal holds at most this
    /// many directory streams at once.
    static let recursiveRemovalDescriptorBudget = 16

    private struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private enum BoundedRemovalStep {
        case child(
            name: [CChar],
            originalUnlinkCode: Int32?
        )
        case empty
    }

    /// Empties a directory tree of any depth while holding one directory
    /// descriptor across levels (plus a transient scan descriptor).
    ///
    /// Descends one level at a time, closing the parent, and climbs back through
    /// `..`. Every ascent is checked against the device/inode recorded on the way
    /// down; a mismatch means the tree was moved concurrently, and removal stops
    /// with `ESTALE` instead of deleting outside the requested tree.
    ///
    /// Ownership of `rootDescriptor` is consumed. The root directory itself is
    /// left in place for the caller to remove.
    static func removeDirectoryContentsBounded(
        _ rootDescriptor: Int32,
        url: URL
    ) throws {
        var current = rootDescriptor
        var descent: [(name: [CChar], parent: DirectoryIdentity)] = []

        defer {
            _ = systemClose(
                current
            )
        }

        while true {
            switch try nextBoundedRemovalStep(
                current,
                url: url
            ) {
            case .child(let name, let originalUnlinkCode):
                let parent = try directoryIdentity(
                    current,
                    url: url
                )
                let child = name.withUnsafeBufferPointer {
                    systemOpenDirectoryAt(
                        current,
                        $0.baseAddress!
                    )
                }

                guard child >= 0 else {
                    let openCode = errno

                    guard openCode == ENOTDIR
                            || openCode == ELOOP
                    else {
                        throw FileSystemError(
                            operation: .remove,
                            url: url,
                            errno: openCode
                        )
                    }

                    // Replaced by a non-directory since readdir: O_NOFOLLOW
                    // refused it, so unlink the leaf itself.
                    let unlinked = name.withUnsafeBufferPointer {
                        systemUnlinkAt(
                            current,
                            $0.baseAddress!,
                            0
                        )
                    }

                    guard unlinked == 0 else {
                        let retryCode = errno

                        throw FileSystemError(
                            operation: .remove,
                            url: url,
                            errno: retryCode == ENOTDIR
                                ? originalUnlinkCode ?? retryCode
                                : retryCode
                        )
                    }

                    continue
                }

                _ = systemClose(
                    current
                )
                current = child
                descent.append(
                    (name, parent)
                )

            case .empty:
                guard let level = descent.popLast() else {
                    return
                }

                let parent = "..".withCString {
                    systemOpenDirectoryAt(
                        current,
                        $0
                    )
                }

                guard parent >= 0 else {
                    throw FileSystemError(
                        operation: .remove,
                        url: url,
                        errno: errno
                    )
                }

                let identity: DirectoryIdentity

                do {
                    identity = try directoryIdentity(
                        parent,
                        url: url
                    )
                } catch {
                    _ = systemClose(
                        parent
                    )
                    throw error
                }

                guard identity == level.parent else {
                    _ = systemClose(
                        parent
                    )
                    throw FileSystemError(
                        operation: .remove,
                        url: url,
                        errno: ESTALE
                    )
                }

                _ = systemClose(
                    current
                )
                current = parent

                let removed = level.name.withUnsafeBufferPointer {
                    systemUnlinkAt(
                        current,
                        $0.baseAddress!,
                        AT_REMOVEDIR
                    )
                }

                guard removed == 0 else {
                    throw FileSystemError(
                        operation: .remove,
                        url: url,
                        errno: errno
                    )
                }
            }
        }
    }

    /// Unlinks non-directory entries of `descriptor` until it finds a directory
    /// (or an entry unlink refused as one), which it returns by name.
    ///
    /// Scans through a fresh descriptor for `.`, so every scan starts at the
    /// first entry and `descriptor` itself is never consumed.
    private static func nextBoundedRemovalStep(
        _ descriptor: Int32,
        url: URL
    ) throws -> BoundedRemovalStep {
        let scanDescriptor = ".".withCString {
            systemOpenDirectoryAt(
                descriptor,
                $0
            )
        }

        guard scanDescriptor >= 0 else {
            throw FileSystemError(
                operation: .remove,
                url: url,
                errno: errno
            )
        }

        guard let directory =
                fdopendir(
                    scanDescriptor
                )
        else {
            let code = errno
            _ = systemClose(
                scanDescriptor
            )

            throw FileSystemError(
                operation: .remove,
                url: url,
                errno: code
            )
        }

        defer {
            closedir(
                directory
            )
        }

        while true {
            errno = 0

            guard let entry =
                    readdir(
                        directory
                    )
            else {
                let code = errno

                if code != 0 {
                    throw FileSystemError(
                        operation: .remove,
                        url: url,
                        errno: code
                    )
                }

                return .empty
            }

            let step: BoundedRemovalStep? = try withDirectoryEntryNameCString(
                entry
            ) {
                name in

                if isDotDirectoryEntry(
                    name
                ) {
                    return nil
                }

                let copy = Array(
                    UnsafeBufferPointer(
                        start: name,
                        count: cStringLength(name) + 1
                    )
                )

                if Int32(entry.pointee.d_type) == Int32(DT_DIR) {
                    return .child(
                        name: copy,
                        originalUnlinkCode: nil
                    )
                }

                if systemUnlinkAt(
                    descriptor,
                    name,
                    0
                ) == 0 {
                    return nil
                }

                let unlinkCode = errno

                guard unlinkCode == EISDIR
                        || unlinkCode == EPERM
                else {
                    throw FileSystemError(
                        operation: .remove,
                        url: url,
                        errno: unlinkCode
                    )
                }

                return .child(
                    name: copy,
                    originalUnlinkCode: unlinkCode
                )
            }

            if let step {
                return step
            }
        }
    }

    private static func directoryIdentity(
        _ descriptor: Int32,
        url: URL
    ) throws -> DirectoryIdentity {
        var info = stat()

        guard fstat(
            descriptor,
            &info
        ) == 0 else {
            throw FileSystemError(
                operation: .remove,
                url: url,
                errno: errno
            )
        }

        return .init(
            device: UInt64(
                truncatingIfNeeded: info.st_dev
            ),
            inode: UInt64(
                truncatingIfNeeded: info.st_ino
            )
        )
    }

    @inline(__always)
    static func withDirectoryEntryNameCString<Result>(
        _ pointer:
            UnsafeMutablePointer<dirent>,
        body:
            (UnsafePointer<CChar>) throws -> Result
    ) rethrows -> Result {
        let capacity =
            MemoryLayout.size(
                ofValue:
                    pointer.pointee.d_name
            )

        return try withUnsafePointer(
            to: &pointer.pointee.d_name
        ) {
            nameStorage in

            try nameStorage.withMemoryRebound(
                to: CChar.self,
                capacity: capacity
            ) {
                try body(
                    $0
                )
            }
        }
    }

    @inline(__always)
    static func isDotDirectoryEntry(
        _ pointer:
            UnsafePointer<CChar>
    ) -> Bool {
        guard pointer[0] == CChar(46)
        else {
            return false
        }

        if pointer[1] == 0 {
            return true
        }

        return pointer[1] == CChar(46)
            && pointer[2] == 0
    }

    @inline(__always)
    static func mutationURL(
        _ input: URL
    ) -> URL {
        input.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                return input.standardizedFileURL
            }

            if containsLexicalDotComponent(
                pointer
            ) {
                return input.standardizedFileURL
            }

            return input
        }
    }

    @inline(__always)
    static func containsLexicalDotComponent(
        _ pointer: UnsafePointer<CChar>
    ) -> Bool {
        var index = 0

        while pointer[index] != 0 {
            let beginsComponent =
                index == 0
                || pointer[
                    index - 1
                ] == CChar(47)

            if beginsComponent,
               pointer[index] == CChar(46)
            {
                let next =
                    pointer[
                        index + 1
                    ]

                if next == 0
                    || next == CChar(47)
                {
                    return true
                }

                if next == CChar(46) {
                    let after =
                        pointer[
                            index + 2
                        ]

                    if after == 0
                        || after == CChar(47)
                    {
                        return true
                    }
                }
            }

            index += 1
        }

        return false
    }

    static func ensureDirectory(
        _ storage:
            UnsafeMutableBufferPointer<CChar>,
        length: Int,
        url: URL
    ) throws {
        guard let baseAddress =
                storage.baseAddress
        else {
            throw FileSystemError(
                operation:
                    .create_directory,
                url: url,
                errno: EINVAL
            )
        }

        if systemMkdir(
            baseAddress
        ) == 0 {
            return
        }

        let code =
            errno

        if code == EEXIST,
           systemPathIsDirectory(
            baseAddress
           )
        {
            return
        }

        guard code == ENOENT else {
            throw FileSystemError(
                operation:
                    .create_directory,
                url: url,
                errno: code
            )
        }

        guard length > 1 else {
            throw FileSystemError(
                operation:
                    .create_directory,
                url: url,
                errno: code
            )
        }

        var slashIndex =
            length - 1

        while slashIndex > 0,
              storage[
                slashIndex
              ] != CChar(47)
        {
            slashIndex -= 1
        }

        let parentLength =
            max(
                1,
                slashIndex
            )

        let saved =
            storage[
                parentLength
            ]
        storage[
            parentLength
        ] = 0

        do {
            try ensureDirectory(
                storage,
                length:
                    parentLength,
                url: url
            )
        } catch {
            storage[
                parentLength
            ] = saved
            throw error
        }

        storage[
            parentLength
        ] = saved

        guard systemMkdir(
            baseAddress
        ) == 0 else {
            let retryCode =
                errno

            if retryCode == EEXIST,
               systemPathIsDirectory(
                baseAddress
               )
            {
                return
            }

            throw FileSystemError(
                operation:
                    .create_directory,
                url: url,
                errno: retryCode
            )
        }
    }

    static func systemPathIsDirectory(
        _ pointer:
            UnsafePointer<CChar>
    ) -> Bool {
        var info = stat()

        guard systemStat(
            pointer,
            &info
        ) == 0 else {
            return false
        }

        return info.st_mode
            & mode_t(
                S_IFMT
            )
            == mode_t(
                S_IFDIR
            )
    }

    static func copyCString(
        _ source:
            UnsafePointer<CChar>,
        into destination:
            UnsafeMutableBufferPointer<CChar>
    ) -> Bool {
        var index = 0

        while source[
            index
        ] != 0 {
            guard index
                    < destination.count - 1
            else {
                return false
            }

            destination[
                index
            ] = source[
                index
            ]
            index += 1
        }

        destination[
            index
        ] = 0
        return true
    }

    static func cStringLength(
        _ pointer:
            UnsafePointer<CChar>
    ) -> Int {
        var count = 0

        while pointer[
            count
        ] != 0 {
            count += 1
        }

        return count
    }
}

@inline(__always)
private func systemMkdir(
    _ pointer:
        UnsafePointer<CChar>
) -> Int32 {
    #if canImport(Darwin)
    mkdirat(
        AT_FDCWD,
        pointer,
        mode_t(
            0o777
        )
    )
    #elseif canImport(Glibc)
    Glibc.mkdir(
        pointer,
        mode_t(
            0o777
        )
    )
    #endif
}

#if canImport(Darwin)
@inline(__always)
private func systemMkpathAtCurrentWorkingDirectory(
    _ pointer:
        UnsafePointer<CChar>
) -> Int32 {
    mkpathat_np(
        AT_FDCWD,
        pointer,
        mode_t(
            0o777
        )
    )
}
#endif


@inline(__always)
private func systemOpenDirectoryAt(
    _ descriptor: Int32,
    _ pointer:
        UnsafePointer<CChar>
) -> Int32 {
    openat(
        descriptor,
        pointer,
        O_RDONLY
            | O_DIRECTORY
            | O_CLOEXEC
            | O_NOFOLLOW
    )
}

@inline(__always)
private func systemUnlinkAt(
    _ descriptor: Int32,
    _ pointer:
        UnsafePointer<CChar>,
    _ flags: Int32
) -> Int32 {
    unlinkat(
        descriptor,
        pointer,
        flags
    )
}

@inline(__always)
private func systemClose(
    _ descriptor: Int32
) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(
        descriptor
    )
    #elseif canImport(Glibc)
    Glibc.close(
        descriptor
    )
    #endif
}

@inline(__always)
private func systemLstat(
    _ pointer:
        UnsafePointer<CChar>,
    _ info:
        UnsafeMutablePointer<stat>
) -> Int32 {
    #if canImport(Darwin)
    Darwin.lstat(
        pointer,
        info
    )
    #elseif canImport(Glibc)
    Glibc.lstat(
        pointer,
        info
    )
    #endif
}

@inline(__always)
private func systemStat(
    _ pointer:
        UnsafePointer<CChar>,
    _ info:
        UnsafeMutablePointer<stat>
) -> Int32 {
    fstatat(
        AT_FDCWD,
        pointer,
        info,
        0
    )
}

@inline(__always)
private func systemUnlink(
    _ pointer:
        UnsafePointer<CChar>
) -> Int32 {
    #if canImport(Darwin)
    Darwin.unlink(
        pointer
    )
    #elseif canImport(Glibc)
    Glibc.unlink(
        pointer
    )
    #endif
}

@inline(__always)
private func systemRmdir(
    _ pointer:
        UnsafePointer<CChar>
) -> Int32 {
    #if canImport(Darwin)
    Darwin.rmdir(
        pointer
    )
    #elseif canImport(Glibc)
    Glibc.rmdir(
        pointer
    )
    #endif
}

#if canImport(Darwin)
@inline(__always)
private func systemRenameSwap(
    _ source:
        UnsafePointer<CChar>,
    _ destination:
        UnsafePointer<CChar>
) -> Int32 {
    Darwin.renameatx_np(
        AT_FDCWD,
        source,
        AT_FDCWD,
        destination,
        UInt32(
            RENAME_SWAP
        )
    )
}

@inline(__always)
private func systemSetBirthTime(
    _ pointer:
        UnsafePointer<CChar>,
    _ birthTime: timespec
) -> Int32 {
    var attributes =
        attrlist()
    attributes.bitmapcount =
        UInt16(
            ATTR_BIT_MAP_COUNT
        )
    attributes.commonattr =
        attrgroup_t(
            ATTR_CMN_CRTIME
        )

    var value =
        birthTime

    return setattrlist(
        pointer,
        &attributes,
        &value,
        MemoryLayout<
            timespec
        >.size,
        UInt32(
            FSOPT_NOFOLLOW
        )
    )
}

@inline(__always)
private func systemApplyReplaceMetadata(
    _ pointer:
        UnsafePointer<CChar>,
    info: stat,
    acl:
        NativeCapturedExtendedACL,
    currentACLKnownAbsent: Bool
) -> Int32 {
    guard Darwin.chmod(
        pointer,
        info.st_mode
            & mode_t(
                0o7777
            )
    ) == 0 else {
        return errno
    }

    guard systemSetBirthTime(
        pointer,
        info.st_birthtimespec
    ) == 0 else {
        return errno
    }

    guard systemApplyExtendedACL(
        pointer,
        acl: acl,
        currentACLKnownAbsent:
            currentACLKnownAbsent
    ) == 0 else {
        return errno
    }

    return 0
}

@inline(__always)
private func systemApplyExtendedACL(
    _ pointer:
        UnsafePointer<CChar>,
    acl:
        NativeCapturedExtendedACL,
    currentACLKnownAbsent: Bool
) -> Int32 {
    if let value =
            acl.value
    {
        guard acl_set_file(
            pointer,
            ACL_TYPE_EXTENDED,
            value
        ) == 0 else {
            return errno
        }

        return 0
    }

    // The common ordinary-file case has no extended ACL on either object.
    // Do not allocate or issue an ACL-setting syscall when there is nothing
    // to change.
    if currentACLKnownAbsent {
        return 0
    }

    // Darwin represents clearing an extended ACL by assigning a valid empty
    // ACL object.
    guard let empty =
            acl_init(
                0
            )
    else {
        return errno
    }

    defer {
        _ = acl_free(
            UnsafeMutableRawPointer(
                empty
            )
        )
    }

    guard acl_set_file(
        pointer,
        ACL_TYPE_EXTENDED,
        empty
    ) == 0 else {
        return errno
    }

    return 0
}
#endif

#if canImport(Glibc)
private typealias LinuxRenameAt2 = @convention(c) (
    Int32,
    UnsafePointer<CChar>?,
    Int32,
    UnsafePointer<CChar>?,
    UInt32
) -> Int32

/// `renameat2`, resolved at runtime: the Glibc module does not import it, and
/// glibc before 2.28 does not export it.
nonisolated(unsafe) private let linuxRenameAt2: LinuxRenameAt2? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "renameat2")
    else {
        return nil
    }

    return unsafeBitCast(
        symbol,
        to: LinuxRenameAt2.self
    )
}()

/// `RENAME_NOREPLACE` from <linux/fs.h>; not imported by the Glibc module.
private let linuxRenameNoReplace: UInt32 = 1
#endif

/// Renames `source` to `destination`, failing with `EEXIST` instead of replacing
/// an existing destination.
///
/// Darwin uses `renamex_np(RENAME_EXCL)`. Linux uses `renameat2(RENAME_NOREPLACE)`,
/// which is atomic; only when the kernel, libc, or filesystem lacks it (`ENOSYS`,
/// `EINVAL`, or no symbol) does it fall back to an `lstat` preflight plus `rename`,
/// which narrows but cannot close the check-then-rename window.
@inline(__always)
private func systemRenameNoReplace(
    _ source:
        UnsafePointer<CChar>,
    _ destination:
        UnsafePointer<CChar>
) -> Int32 {
    #if canImport(Darwin)
    return Darwin.renamex_np(
        source,
        destination,
        UInt32(
            RENAME_EXCL
        )
    )
    #elseif canImport(Glibc)
    if let renameAt2 = linuxRenameAt2 {
        let result = renameAt2(
            AT_FDCWD,
            source,
            AT_FDCWD,
            destination,
            linuxRenameNoReplace
        )

        if result == 0 {
            return 0
        }

        let code = errno

        guard code == ENOSYS
                || code == EINVAL
        else {
            return result
        }
    }

    var destinationInfo = stat()

    if Glibc.lstat(
        destination,
        &destinationInfo
    ) == 0 {
        errno = EEXIST
        return -1
    }

    guard errno == ENOENT else {
        return -1
    }

    return Glibc.rename(
        source,
        destination
    )
    #endif
}
