import Foundation

public struct FileInspector: Sendable {
    public let url: URL
    public let fileSystem: FileSystem

    public init(
        _ url: URL,
        fileSystem: FileSystem = .default
    ) {
        self.url = url.standardizedFileURL
        self.fileSystem = fileSystem
    }

    /// Describes the item at `url`. A final-component symlink is described
    /// itself unless `followingSymlinks` is true, in which case its target is
    /// described and a dangling link reports `existed: false`.
    public func inspect(
        followingSymlinks: Bool = false
    ) throws -> FileMetadataSnapshot {
        if case .c = fileSystem.implementation {
            return try NativeFileSystem.inspect(
                url,
                followingSymlinks: followingSymlinks
            )
        }

        let attributes: [FileAttributeKey: Any]

        do {
            attributes = try FileManager.default.attributesOfItem(
                atPath: followingSymlinks
                    ? url.resolvingSymlinksInPath().path
                    : url.path
            )
        } catch {
            if isMissingFileError(
                error
            ) {
                return .init(
                    url: url,
                    existed: false,
                    byteCount: nil,
                    modifiedAt: nil,
                    identity: nil,
                    kind: nil
                )
            }

            if let error = FileSystemError.wrapping(
                error,
                operation: .inspect,
                url: url
            ) {
                throw error
            }

            throw FileInspectionError.io(
                url,
                message: error.localizedDescription
            )
        }

        return .init(
            url: url,
            existed: true,
            byteCount: byteCount(
                from: attributes
            ),
            modifiedAt: attributes[.modificationDate] as? Date,
            identity: identity(
                from: attributes
            ),
            kind: kind(
                from: attributes
            )
        )
    }
}

private extension FileInspector {
    func byteCount(
        from attributes: [FileAttributeKey: Any]
    ) -> Int? {
        (
            attributes[.size] as? NSNumber
        )?.intValue
    }

    func identity(
        from attributes: [FileAttributeKey: Any]
    ) -> FileIdentity? {
        guard
            let deviceID = (
                attributes[.systemNumber] as? NSNumber
            )?.uint64Value,
            let fileID = (
                attributes[.systemFileNumber] as? NSNumber
            )?.uint64Value
        else {
            return nil
        }

        return .init(
            deviceID: deviceID,
            fileID: fileID
        )
    }

    func kind(
        from attributes: [FileAttributeKey: Any]
    ) -> FileKind {
        guard let type = attributes[.type] as? FileAttributeType else {
            return .other
        }

        switch type {
        case .typeRegular:
            return .file

        case .typeDirectory:
            return .directory

        case .typeSymbolicLink:
            return .symlink

        default:
            return .other
        }
    }

    func isMissingFileError(
        _ error: Error
    ) -> Bool {
        let error = error as NSError

        guard error.domain == NSCocoaErrorDomain else {
            return false
        }

        return error.code == CocoaError.Code.fileNoSuchFile.rawValue
            || error.code == CocoaError.Code.fileReadNoSuchFile.rawValue
    }
}
