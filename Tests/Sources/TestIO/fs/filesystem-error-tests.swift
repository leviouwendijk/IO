import Foundation
import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    static func testFileSystemErrorModel() throws {
        try withFileSystemFixture { fixture in
            let mappings: [
                (
                    errno: Int32,
                    reason: FileSystemError.Reason
                )
            ] = [
                (ENOENT, .not_found),
                (EACCES, .permission_denied),
                (EPERM, .permission_denied),
                (ENOTDIR, .not_directory),
                (ELOOP, .symbolic_link_loop),
                (ENAMETOOLONG, .name_too_long),
                (EMFILE, .process_file_limit),
                (ENFILE, .system_file_limit),
                (EIO, .io),
                (EINVAL, .invalid_argument),
            ]

            for mapping in mappings {
                let error = FileSystemError(
                    operation: .inspect,
                    url: fixture.regularFile,
                    errno: mapping.errno
                )

                try expectEqual(
                    error.errno,
                    mapping.errno,
                    "filesystem error retains raw errno"
                )
                try expectEqual(
                    error.reason,
                    mapping.reason,
                    "filesystem errno mapping"
                )
                try expectEqual(
                    error.operation,
                    .inspect,
                    "filesystem error operation"
                )
                try expectEqual(
                    error.url,
                    fixture.regularFile.standardizedFileURL,
                    "filesystem error url"
                )
            }

            let unknown = FileSystemError(
                operation: .inspect,
                url: fixture.regularFile,
                errno: 0x7fff
            )

            try expectEqual(
                unknown.reason,
                .unknown,
                "unknown errno mapping"
            )

            do {
                _ = try FileSystem.c.directory.entries(
                    fixture.missing
                )

                throw TestFailure(
                    message:
                        "c missing enumeration must throw FileSystemError"
                )
            } catch let error as FileSystemError {
                try expectEqual(
                    error.operation,
                    .enumerate_directory,
                    "c missing enumeration operation"
                )
                try expectEqual(
                    error.url,
                    fixture.missing.standardizedFileURL,
                    "c missing enumeration url"
                )
                try expectEqual(
                    error.errno,
                    ENOENT,
                    "c missing enumeration errno"
                )
                try expectEqual(
                    error.reason,
                    .not_found,
                    "c missing enumeration reason"
                )
            }

            do {
                _ = try FileSystem.c.directory.entries(
                    fixture.regularFile
                )

                throw TestFailure(
                    message:
                        "c file enumeration must throw FileSystemError"
                )
            } catch let error as FileSystemError {
                try expectEqual(
                    error.operation,
                    .enumerate_directory,
                    "c non-directory operation"
                )
                try expectEqual(
                    error.reason,
                    .not_directory,
                    "c non-directory reason"
                )
            }

            do {
                _ = try DirectoryInspector(
                    fixture.missing,
                    fileSystem: .c
                ).isEmpty()

                throw TestFailure(
                    message:
                        "c missing emptiness probe must throw FileSystemError"
                )
            } catch let error as FileSystemError {
                try expectEqual(
                    error.operation,
                    .probe_directory_empty,
                    "c emptiness operation"
                )
                try expectEqual(
                    error.errno,
                    ENOENT,
                    "c emptiness errno"
                )
            }

            do {
                _ = try DirectoryInspector(
                    fixture.missing,
                    fileSystem: .c
                ).entries()

                throw TestFailure(
                    message:
                        "DirectoryInspector must preserve FileSystemError"
                )
            } catch let error as FileSystemError {
                try expectEqual(
                    error.operation,
                    .enumerate_directory,
                    "DirectoryInspector preserved operation"
                )
                try expectEqual(
                    error.reason,
                    .not_found,
                    "DirectoryInspector preserved reason"
                )
            }

            do {
                _ = try FileSystem.foundation.directory.entries(
                    fixture.missing
                )

                throw TestFailure(
                    message:
                        "Foundation missing enumeration must throw"
                )
            } catch let error as FileSystemError {
                try expectEqual(
                    error.operation,
                    .enumerate_directory,
                    "Foundation missing enumeration operation"
                )
                try expectEqual(
                    error.reason,
                    .not_found,
                    "Foundation missing enumeration reason"
                )
            }
        }
    }
}
