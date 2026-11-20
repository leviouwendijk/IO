import Foundation

#if canImport(Darwin)
import Darwin
#endif

extension TestIO {
    static func runFileSystemMutationReplaceDarwinMetadataCharacterization() throws {
        #if canImport(Darwin)
        try runMutationReplaceFinderInfoCharacterization()
        try runMutationReplaceFinderCommentCharacterization()
        #else
        print(
            "filesystem mutation replace Darwin metadata characterization is Darwin-only"
        )
        #endif
    }
}

#if canImport(Darwin)
extension TestIO {
    static let mutationReplaceDarwinFinderInfoXattr =
        "com.apple.FinderInfo"

    static let mutationReplaceDarwinFinderCommentXattr =
        "com.apple.metadata:kMDItemFinderComment"

    static func runMutationReplaceFinderInfoCharacterization() throws {
        let root =
            temporaryFileSystemRoot(
                prefix:
                    "io-fs-replace-finder-info"
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
            count: 128
        ).write(
            to: original
        )
        try Data(
            repeating: 0x22,
            count: 128
        ).write(
            to: replacement
        )

        // FinderInfo is 32 bytes. The classic Finder flags field occupies
        // bytes 8...9 in big-endian order. The color/label bits are the
        // low three nonzero bits of the UInt16 flags value (mask 0x000E).
        // Keep the payload structurally sized, vary both label bits and
        // unrelated bytes, then observe what Foundation carries forward.
        var originalFinderInfo =
            [UInt8](
                repeating: 0,
                count: 32
            )
        originalFinderInfo[0] = 0x11
        originalFinderInfo[9] = 0x0A
        originalFinderInfo[31] = 0x11

        var replacementFinderInfo =
            [UInt8](
                repeating: 0,
                count: 32
            )
        replacementFinderInfo[0] = 0x22
        replacementFinderInfo[9] = 0x04
        replacementFinderInfo[31] = 0x22

        try mutationReplaceDarwinSetXattr(
            original,
            name:
                mutationReplaceDarwinFinderInfoXattr,
            bytes:
                originalFinderInfo
        )
        try mutationReplaceDarwinSetXattr(
            replacement,
            name:
                mutationReplaceDarwinFinderInfoXattr,
            bytes:
                replacementFinderInfo
        )

        let originalBefore =
            try mutationReplaceDarwinReadXattr(
                original,
                name:
                    mutationReplaceDarwinFinderInfoXattr
            )
        let replacementBefore =
            try mutationReplaceDarwinReadXattr(
                replacement,
                name:
                    mutationReplaceDarwinFinderInfoXattr
            )

        _ = try manager.replaceItemAt(
            original,
            withItemAt:
                replacement
        )

        let after =
            try mutationReplaceDarwinReadXattr(
                original,
                name:
                    mutationReplaceDarwinFinderInfoXattr
            )

        print("")
        print("filesystem mutation replace FinderInfo characterization")
        print("oracle: FileManager.default.replaceItemAt default options")
        print("")

        print(
            "original_finder_info_hex: "
            + mutationReplaceDarwinHex(
                originalBefore
            )
        )
        print(
            "replacement_finder_info_hex: "
            + mutationReplaceDarwinHex(
                replacementBefore
            )
        )
        print(
            "result_finder_info_hex: "
            + mutationReplaceDarwinHex(
                after
            )
        )
        print(
            "result_byte_source_map: "
            + mutationReplaceDarwinByteSourceMap(
                after,
                original:
                    originalBefore,
                replacement:
                    replacementBefore
            )
        )
        print(
            "original_label_bits: "
            + mutationReplaceDarwinLabelBits(
                originalBefore
            )
        )
        print(
            "replacement_label_bits: "
            + mutationReplaceDarwinLabelBits(
                replacementBefore
            )
        )
        print(
            "result_label_bits: "
            + mutationReplaceDarwinLabelBits(
                after
            )
        )
        print("")
    }

    static func runMutationReplaceFinderCommentCharacterization() throws {
        let root =
            temporaryFileSystemRoot(
                prefix:
                    "io-fs-replace-finder-comment"
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
            count: 128
        ).write(
            to: original
        )
        try Data(
            repeating: 0x22,
            count: 128
        ).write(
            to: replacement
        )

        let originalComment =
            "original-comment"
        let replacementComment =
            "replacement-comment"

        let originalCommentData =
            try PropertyListSerialization.data(
                fromPropertyList:
                    originalComment,
                format: .binary,
                options: 0
            )
        let replacementCommentData =
            try PropertyListSerialization.data(
                fromPropertyList:
                    replacementComment,
                format: .binary,
                options: 0
            )

        try mutationReplaceDarwinSetXattr(
            original,
            name:
                mutationReplaceDarwinFinderCommentXattr,
            bytes:
                Array(
                    originalCommentData
                )
        )
        try mutationReplaceDarwinSetXattr(
            replacement,
            name:
                mutationReplaceDarwinFinderCommentXattr,
            bytes:
                Array(
                    replacementCommentData
                )
        )

        let originalBefore =
            try mutationReplaceDarwinReadFinderComment(
                original
            )
        let replacementBefore =
            try mutationReplaceDarwinReadFinderComment(
                replacement
            )

        _ = try manager.replaceItemAt(
            original,
            withItemAt:
                replacement
        )

        let after =
            try mutationReplaceDarwinReadFinderComment(
                original
            )

        let source: String

        if after == originalBefore {
            source = "original"
        } else if after == replacementBefore {
            source = "replacement"
        } else if after == nil {
            source = "missing"
        } else {
            source = "other"
        }

        print("filesystem mutation replace Finder comment characterization")
        print("oracle: FileManager.default.replaceItemAt default options")
        print("")
        print(
            "original_comment: \(originalBefore ?? "<missing>")"
        )
        print(
            "replacement_comment: \(replacementBefore ?? "<missing>")"
        )
        print(
            "result_comment: \(after ?? "<missing>")"
        )
        print(
            "finder_comment_source: \(source)"
        )
        print("")
    }

    static func mutationReplaceDarwinReadFinderComment(
        _ url: URL
    ) throws -> String? {
        guard let bytes =
                try mutationReplaceDarwinReadXattr(
                    url,
                    name:
                        mutationReplaceDarwinFinderCommentXattr
                )
        else {
            return nil
        }

        let value =
            try PropertyListSerialization.propertyList(
                from:
                    Data(
                        bytes
                    ),
                options: [],
                format: nil
            )

        return value as? String
    }

    static func mutationReplaceDarwinSetXattr(
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
                            "Darwin replace metadata path borrow failed"
                    )
                }

                return try name.withCString {
                    namePointer in

                    try bytes.withUnsafeBytes {
                        buffer in

                        guard let base =
                                buffer.baseAddress
                        else {
                            throw TestFailure(
                                message:
                                    "Darwin replace metadata xattr buffer unavailable"
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
                    "Darwin replace metadata setxattr \(name) failed errno \(errno)"
            )
        }
    }

    static func mutationReplaceDarwinReadXattr(
        _ url: URL,
        name: String
    ) throws -> [UInt8]? {
        try url.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                throw TestFailure(
                    message:
                        "Darwin replace metadata path borrow failed"
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
                            "Darwin replace metadata getxattr size \(name) failed errno \(errno)"
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
                            "Darwin replace metadata getxattr read \(name) failed errno \(errno)"
                    )
                }

                return bytes
            }
        }
    }

    static func mutationReplaceDarwinHex(
        _ bytes: [UInt8]?
    ) -> String {
        guard let bytes else {
            return "<missing>"
        }

        return bytes
            .map {
                String(
                    format:
                        "%02x",
                    $0
                )
            }
            .joined()
    }

    static func mutationReplaceDarwinByteSourceMap(
        _ result: [UInt8]?,
        original: [UInt8]?,
        replacement: [UInt8]?
    ) -> String {
        guard let result else {
            return "<missing>"
        }

        return result.enumerated()
            .map {
                index,
                byte in

                if let original,
                   index < original.count,
                   byte == original[
                    index
                   ]
                {
                    return "O"
                }

                if let replacement,
                   index < replacement.count,
                   byte == replacement[
                    index
                   ]
                {
                    return "R"
                }

                return "X"
            }
            .joined()
    }

    static func mutationReplaceDarwinLabelBits(
        _ bytes: [UInt8]?
    ) -> String {
        guard let bytes,
              bytes.count >= 10
        else {
            return "<missing>"
        }

        let flags =
            (
                UInt16(
                    bytes[8]
                )
                << 8
            )
            | UInt16(
                bytes[9]
            )
        let label =
            flags
            & 0x000E

        return String(
            format:
                "0x%04x",
            label
        )
    }
}
#endif
