import Errors
import Foundation

/// `FileSystemError`'s identity, disposition and fields for the Errors library.
/// Its message already reads well ("Filesystem move failed for …: no_space"),
/// so it keeps `LocalizedError` and is not a `PresentableError`. All of this is
/// computed only when the error is presented; building and throwing the error
/// on IO's paths costs nothing more.
extension FileSystemError: ErrorNamespaced, ErrorDispositionProviding, ErrorDiagnosticFieldsProviding {
    public static let errorNamespace = "io.filesystem"

    /// The reason, not the operation: the operation is a field.
    public var errorCode: String {
        reason.rawValue
    }

    public var errorDisposition: ErrorDisposition? {
        switch reason {
        case .not_found, .not_directory, .is_directory, .already_exists,
             .directory_not_empty, .name_too_long, .invalid_argument,
             .symbolic_link_loop, .cross_device:
            return .invalid_input
        case .permission_denied, .read_only_file_system:
            return .requires_access
        case .busy, .process_file_limit, .system_file_limit:
            return .transient
        case .no_space, .file_too_large:
            return .permanent
        case .io, .unknown:
            return nil
        }
    }

    public var errorDiagnosticFields: [ErrorDiagnosticField] {
        [
            .init(key: "io.operation", value: .string(operation.rawValue)),
            .init(key: "io.errno", value: .integer(Int(errno))),
            .init(key: .path, value: .string(url.path), sensitivity: .potentially_sensitive),
        ]
    }
}
