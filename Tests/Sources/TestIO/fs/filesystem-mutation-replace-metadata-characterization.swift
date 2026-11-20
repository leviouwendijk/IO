import Foundation
import IO

#if canImport(Darwin)
import Darwin
#endif

extension TestIO {
    static func runFileSystemMutationReplaceMetadataCharacterization() throws {
        #if canImport(Darwin)
        try runMutationReplaceMetadataCharacterizationDarwin()
        #else
        print(
            "filesystem mutation replace metadata characterization is Darwin-only"
        )
        #endif
    }
}

#if canImport(Darwin)
extension TestIO {
    struct MutationReplaceMetadataObservation {
        let exists: Bool
        let mode: UInt32?
        let modificationSeconds: Int64?
        let creationSeconds: Int64?
        let flags: UInt32?
        let finderInfo: [UInt8]?
        let spotlightComment: [UInt8]?
        let customXattr: [UInt8]?
    }

    static let mutationReplaceFinderInfoXattr =
        "com.apple.FinderInfo"
    static let mutationReplaceSpotlightCommentXattr =
        "com.apple.metadata:kMDItemFinderComment"
    static let mutationReplaceCustomXattr =
        "com.example.io.m6b"

    static func runMutationReplaceMetadataCharacterizationDarwin() throws {
        let root =
            temporaryFileSystemRoot(
                prefix:
                    "io-fs-replace-metadata-characterize"
            )
        let manager =
            FileManager.default
        let original =
            root.appendingPathComponent(
                "original"
            )
        let replacement =
            root.appendingPathComponent(
                "replacement"
            )

        try manager.createDirectory(
            at: root,
            withIntermediateDirectories:
                true
        )

        defer {
            try? manager.removeItem(
                at: root
            )
        }

        try Data(
            repeating: 0x11,
            count: 4096
        ).write(
            to: original
        )
        try manager.setAttributes(
            [
                .posixPermissions:
                    NSNumber(
                        value: 0o600
                    ),
                .modificationDate:
                    Date(
                        timeIntervalSince1970:
                            1_600_000_000
                    ),
                .creationDate:
                    Date(
                        timeIntervalSince1970:
                            1_500_000_000
                    ),
            ],
            ofItemAtPath:
                original.path
        )

        try mutationReplaceSetFlags(
            original,
            flags:
                UInt32(
                    UF_HIDDEN
                )
        )
        try mutationReplaceSetXattr(
            original,
            name:
                mutationReplaceFinderInfoXattr,
            bytes:
                Array(
                    repeating: 0x11,
                    count: 32
                )
        )
        try mutationReplaceSetXattr(
            original,
            name:
                mutationReplaceSpotlightCommentXattr,
            bytes:
                Array(
                    "original-comment".utf8
                )
        )
        try mutationReplaceSetXattr(
            original,
            name:
                mutationReplaceCustomXattr,
            bytes:
                Array(
                    "original-custom".utf8
                )
        )

        try Data(
            repeating: 0x22,
            count: 4096
        ).write(
            to: replacement
        )
        try manager.setAttributes(
            [
                .posixPermissions:
                    NSNumber(
                        value: 0o644
                    ),
                .modificationDate:
                    Date(
                        timeIntervalSince1970:
                            1_700_000_000
                    ),
                .creationDate:
                    Date(
                        timeIntervalSince1970:
                            1_750_000_000
                    ),
            ],
            ofItemAtPath:
                replacement.path
        )

        try mutationReplaceSetFlags(
            replacement,
            flags: 0
        )
        try mutationReplaceSetXattr(
            replacement,
            name:
                mutationReplaceFinderInfoXattr,
            bytes:
                Array(
                    repeating: 0x22,
                    count: 32
                )
        )
        try mutationReplaceSetXattr(
            replacement,
            name:
                mutationReplaceSpotlightCommentXattr,
            bytes:
                Array(
                    "replacement-comment".utf8
                )
        )
        try mutationReplaceSetXattr(
            replacement,
            name:
                mutationReplaceCustomXattr,
            bytes:
                Array(
                    "replacement-custom".utf8
                )
        )

        let originalBefore =
            try mutationReplaceMetadataObservation(
                original
            )
        let replacementBefore =
            try mutationReplaceMetadataObservation(
                replacement
            )

        _ = try manager.replaceItemAt(
            original,
            withItemAt:
                replacement
        )

        let after =
            try mutationReplaceMetadataObservation(
                original
            )
        let replacementAfter =
            try mutationReplaceMetadataObservation(
                replacement
            )

        print("")
        print("filesystem mutation replace metadata characterization")
        print("oracle: FileManager.default.replaceItemAt default options")
        print("")

        mutationReplacePrintMetadataSource(
            "mode",
            after.mode,
            original: originalBefore.mode,
            replacement:
                replacementBefore.mode
        )
        mutationReplacePrintMetadataSource(
            "mtime",
            after.modificationSeconds,
            original:
                originalBefore.modificationSeconds,
            replacement:
                replacementBefore.modificationSeconds
        )
        mutationReplacePrintMetadataSource(
            "creation_time",
            after.creationSeconds,
            original:
                originalBefore.creationSeconds,
            replacement:
                replacementBefore.creationSeconds
        )
        mutationReplacePrintMetadataSource(
            "bsd_flags",
            after.flags,
            original:
                originalBefore.flags,
            replacement:
                replacementBefore.flags
        )
        mutationReplacePrintMetadataSource(
            "finder_info_xattr",
            after.finderInfo,
            original:
                originalBefore.finderInfo,
            replacement:
                replacementBefore.finderInfo
        )
        mutationReplacePrintMetadataSource(
            "spotlight_comment_xattr",
            after.spotlightComment,
            original:
                originalBefore.spotlightComment,
            replacement:
                replacementBefore.spotlightComment
        )
        mutationReplacePrintMetadataSource(
            "custom_xattr",
            after.customXattr,
            original:
                originalBefore.customXattr,
            replacement:
                replacementBefore.customXattr
        )

        print(
            "replacement_exists_after: \(replacementAfter.exists)"
        )
        print("")
        print("note: ACL semantics are not characterized by this pass")
        print("")
    }

    static func mutationReplaceMetadataObservation(
        _ url: URL
    ) throws -> MutationReplaceMetadataObservation {
        var info =
            stat()

        let result =
            url.withUnsafeFileSystemRepresentation {
                pointer in

                guard let pointer else {
                    return Int32(-1)
                }

                return Darwin.lstat(
                    pointer,
                    &info
                )
            }

        if result != 0 {
            if errno == ENOENT {
                return .init(
                    exists: false,
                    mode: nil,
                    modificationSeconds: nil,
                    creationSeconds: nil,
                    flags: nil,
                    finderInfo: nil,
                    spotlightComment: nil,
                    customXattr: nil
                )
            }

            throw TestFailure(
                message:
                    "replace metadata lstat failed errno \(errno)"
            )
        }

        return .init(
            exists: true,
            mode:
                UInt32(
                    info.st_mode
                    & mode_t(
                        0o7777
                    )
                ),
            modificationSeconds:
                Int64(
                    info.st_mtimespec.tv_sec
                ),
            creationSeconds:
                Int64(
                    info.st_birthtimespec.tv_sec
                ),
            flags:
                UInt32(
                    info.st_flags
                ),
            finderInfo:
                try mutationReplaceReadXattr(
                    url,
                    name:
                        mutationReplaceFinderInfoXattr
                ),
            spotlightComment:
                try mutationReplaceReadXattr(
                    url,
                    name:
                        mutationReplaceSpotlightCommentXattr
                ),
            customXattr:
                try mutationReplaceReadXattr(
                    url,
                    name:
                        mutationReplaceCustomXattr
                )
        )
    }

    static func mutationReplaceSetFlags(
        _ url: URL,
        flags: UInt32
    ) throws {
        let result =
            url.withUnsafeFileSystemRepresentation {
                pointer in

                guard let pointer else {
                    return Int32(-1)
                }

                return Darwin.chflags(
                    pointer,
                    flags
                )
            }

        guard result == 0 else {
            throw TestFailure(
                message:
                    "replace metadata chflags failed errno \(errno)"
            )
        }
    }

    static func mutationReplaceSetXattr(
        _ url: URL,
        name: String,
        bytes: [UInt8]
    ) throws {
        let result =
            try url.withUnsafeFileSystemRepresentation {
                pointer in

                guard let pointer else {
                    throw TestFailure(
                        message:
                            "replace metadata xattr path borrow failed"
                    )
                }

                return try name.withCString {
                    namePointer in

                    try bytes.withUnsafeBytes {
                        buffer in

                        guard let base =
                                buffer.baseAddress
                                ?? UnsafeRawPointer(
                                    bitPattern: 1
                                )
                        else {
                            throw TestFailure(
                                message:
                                    "replace metadata xattr buffer unavailable"
                            )
                        }

                        return Darwin.setxattr(
                            pointer,
                            namePointer,
                            base,
                            buffer.count,
                            0,
                            0
                        )
                    }
                }
            }

        guard result == 0 else {
            throw TestFailure(
                message:
                    "replace metadata setxattr \(name) failed errno \(errno)"
            )
        }
    }

    static func mutationReplaceReadXattr(
        _ url: URL,
        name: String
    ) throws -> [UInt8]? {
        try url.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                throw TestFailure(
                    message:
                        "replace metadata xattr path borrow failed"
                )
            }

            return try name.withCString {
                namePointer in

                errno = 0

                let count =
                    Darwin.getxattr(
                        pointer,
                        namePointer,
                        nil,
                        0,
                        0,
                        0
                    )

                if count < 0 {
                    if errno == ENOATTR {
                        return nil
                    }

                    throw TestFailure(
                        message:
                            "replace metadata getxattr size \(name) failed errno \(errno)"
                    )
                }

                var bytes =
                    [UInt8](
                        repeating: 0,
                        count: count
                    )

                let readCount =
                    bytes.withUnsafeMutableBytes {
                        buffer in

                        Darwin.getxattr(
                            pointer,
                            namePointer,
                            buffer.baseAddress,
                            buffer.count,
                            0,
                            0
                        )
                    }

                guard readCount == count else {
                    throw TestFailure(
                        message:
                            "replace metadata getxattr read \(name) failed errno \(errno)"
                    )
                }

                return bytes
            }
        }
    }

    static func mutationReplacePrintMetadataSource<Value: Equatable>(
        _ name: String,
        _ after: Value?,
        original: Value?,
        replacement: Value?
    ) {
        let source: String

        if after == original {
            source = "original"
        } else if after == replacement {
            source = "replacement"
        } else if after == nil {
            source = "missing"
        } else {
            source = "other"
        }

        print(
            "\(name)_source: \(source)"
        )
    }
}
#endif
