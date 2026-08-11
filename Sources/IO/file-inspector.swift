import Foundation

public struct FileInspector: Sendable {
    public let url: URL

    public init(
        _ url: URL
    ) {
        self.url = url.standardizedFileURL
    }

    public func inspect() throws -> FileMetadataSnapshot {
        let attributes: [FileAttributeKey: Any]

        do {
            attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
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

        return error.domain == NSCocoaErrorDomain
            && error.code == CocoaError.Code.fileNoSuchFile.rawValue
    }
}
