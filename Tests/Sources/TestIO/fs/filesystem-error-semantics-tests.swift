import Errors
import Foundation
@_spi(Testing) import IO

extension TestIO {
    /// One filesystem error end to end through the Errors library: identity,
    /// message, a field and the disposition.
    static func testFileSystemErrorSemantics() throws {
        let missing = temporaryURL(
            name: "filesystem-error-semantics"
        ).appendingPathComponent("missing")

        do {
            try FileSystem.default.remove(missing)
            throw TestFailure(message: "removing a missing path must fail")
        } catch let error as FileSystemError {
            try expectEqual(error.errorIdentity.raw, "io.filesystem.not_found", "identity is the reason")
            try expectEqual(error.errorDisposition, .invalid_input, "a missing path is an input to change")
            try expect(error.explanation.contains("remove"), "explanation keeps IO's message")

            let report = error.report(for: .diagnostic)
            try expectEqual(report.effectiveDisposition, .invalid_input, "report carries the disposition")
            let fields = Dictionary(
                report.diagnostic.fields.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            try expectEqual(fields["io.operation"]?.value, .string("remove"), "operation field")
            try expectEqual(fields["io.errno"]?.value, .integer(Int(ENOENT)), "errno field")
            try expectEqual(fields["path"]?.sensitivity, .potentially_sensitive, "the path is marked sensitive")
        }

        let full = FileSystemError(operation: .copy, url: missing, errno: ENOSPC)
        try expectEqual(full.errorIdentity.raw, "io.filesystem.no_space", "out of space")
        try expectEqual(full.errorDisposition, .permanent, "a full volume does not clear by retrying")
        try expectEqual(
            FileSystemError(operation: .copy, url: missing, errno: EFBIG).errorIdentity.raw,
            "io.filesystem.file_too_large",
            "past the volume's file size"
        )
    }
}
