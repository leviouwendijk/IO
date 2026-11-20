import IO
import Foundation

extension TestIO {
    /// Verifies ownership constraints at the compiler boundary, not merely at runtime.
    ///
    /// The positive control proves the built IO module is importable by the
    /// child compiler process. Each negative fixture must then fail type checking because
    /// the named resource does not satisfy `Copyable` or because a consumed value is reused.
    static func testOwnershipCompileRejections() throws {
        let moduleSearchPath = try experimentIOModuleSearchPath()

        try expectTypechecks(
            name: "positive-borrow-control",
            source: """
            import IO

            func inspect(
                _ source: borrowing Source,
                _ destination: borrowing Destination,
                _ scanner: borrowing ByteLineScanner
            ) {
                _ = source.bufferedByteCount
                _ = destination.bufferedByteCount
                _ = scanner.statistics.bytesExamined
            }
            """,
            moduleSearchPath: moduleSearchPath
        )

        try expectTypechecks(
            name: "positive-borrowed-lifetime-control",
            source: """
            import IO

            func inspect(
                _ ring: borrowing BorrowedStreamRingBuffer,
                _ source: borrowing BorrowedSource,
                _ destination: borrowing BorrowedDestination
            ) {
                let io = IO.blocking
                _ = io
                _ = ring.capacity
                _ = source.bufferedByteCount
                _ = destination.bufferedByteCount
            }
            """,
            moduleSearchPath: moduleSearchPath
        )

        try expectTypechecks(
            name: "positive-span-view-control",
            source: """
            import IO

            func inspect(
                _ source: borrowing Source,
                _ scanner: inout ByteLineScanner
            ) throws -> Int {
                var total = source.withBytes { $0.byteCount }
                total += source.withReadableRegions { $0.byteCount + $1.byteCount }
                _ = try scanner.scan { fragment in
                    total += fragment.bytes.byteCount
                    return .continue
                }
                return total
            }
            """,
            moduleSearchPath: moduleSearchPath
        )

        try expectTypecheckFailure(
            name: "Source-withBytes-span-cannot-escape",
            source: """
            import IO

            func probe(
                _ source: borrowing Source
            ) -> Int {
                let span = source.withBytes { $0 }
                return span.byteCount
            }
            """,
            moduleSearchPath: moduleSearchPath
        )

        try expectTypecheckFailure(
            name: "ByteLineFragment-cannot-live-in-escapable-wrapper",
            source: """
            import IO

            struct InvalidWrapper {
                var fragment: ByteLineFragment
            }
            """,
            moduleSearchPath: moduleSearchPath
        )

        let noncopyableTypes = [
            "Source",
            "Destination",
            "SystemFileSource",
            "MemorySource",
            "MemoryDestination",
            "ByteLineScanner",
        ]

        for typeName in noncopyableTypes {
            try expectTypecheckFailure(
                name: "\(typeName)-is-not-copyable",
                source: """
                import IO

                func requiresCopyable<T: Copyable>(
                    _ value: T
                ) {}

                func probe(
                    _ value: borrowing \(typeName)
                ) {
                    requiresCopyable(value)
                }
                """,
                moduleSearchPath: moduleSearchPath
            )
        }

        try expectTypecheckFailure(
            name: "Source-cannot-live-in-copyable-wrapper",
            source: """
            import IO

            struct InvalidWrapper: Copyable {
                var source: Source
            }
            """,
            moduleSearchPath: moduleSearchPath
        )

        try expectTypecheckFailure(
            name: "BorrowedStreamRingBuffer-cannot-escape-temporary-storage",
            source: """
            import IO

            func probe() {
                let ring =
                    withUnsafeTemporaryAllocation(
                        of: UInt8.self,
                        capacity: 8
                    ) {
                        storage in

                        let raw =
                            UnsafeMutableRawBufferPointer(
                                start: storage.baseAddress,
                                count: storage.count
                            )

                        return BorrowedStreamRingBuffer(
                            storage: raw
                        )
                    }

                _ = ring
            }
            """,
            moduleSearchPath: moduleSearchPath
        )

        try expectTypecheckFailure(
            name: "BorrowedDestination-cannot-live-in-escapable-wrapper",
            source: """
            import IO

            struct InvalidWrapper: ~Copyable {
                var destination: BorrowedDestination
            }
            """,
            moduleSearchPath: moduleSearchPath
        )

        try expectTypecheckFailure(
            name: "BorrowedSource-cannot-live-in-escapable-wrapper",
            source: """
            import IO

            struct InvalidWrapper: ~Copyable {
                var source: BorrowedSource
            }
            """,
            moduleSearchPath: moduleSearchPath
        )
    }

    private static func experimentIOModuleSearchPath() throws -> URL {
        let executable = URL(
            fileURLWithPath: CommandLine.arguments[0]
        ).standardizedFileURL

        let modules = executable
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Modules",
                isDirectory: true
            )

        guard FileManager.default.fileExists(
            atPath: modules.path
        ) else {
            throw TestFailure(
                message:
                    "could not locate sibling SwiftPM Modules directory at "
                    + modules.path
            )
        }

        return modules
    }

    private static func expectTypechecks(
        name: String,
        source: String,
        moduleSearchPath: URL
    ) throws {
        let result = try typecheckFixture(
            name: name,
            source: source,
            moduleSearchPath: moduleSearchPath
        )

        guard result.status == 0 else {
            throw TestFailure(
                message:
                    "positive compiler fixture '\(name)' failed:\n"
                    + result.diagnostics
            )
        }
    }

    private static func expectTypecheckFailure(
        name: String,
        source: String,
        moduleSearchPath: URL
    ) throws {
        let result = try typecheckFixture(
            name: name,
            source: source,
            moduleSearchPath: moduleSearchPath
        )

        guard result.status != 0 else {
            throw TestFailure(
                message:
                    "negative compiler fixture '\(name)' unexpectedly typechecked"
            )
        }
    }

    private static func typecheckFixture(
        name: String,
        source: String,
        moduleSearchPath: URL
    ) throws -> (
        status: Int32,
        diagnostics: String
    ) {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "tio-ownership-\(UUID().uuidString)",
                isDirectory: true
            )

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: directory
            )
        }

        let file = directory.appendingPathComponent(
            "\(name).swift"
        )
        try source.write(
            to: file,
            atomically: true,
            encoding: .utf8
        )

        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/usr/bin/env"
        )
        process.arguments = [
            "swiftc",
            "-typecheck",
            "-I",
            moduleSearchPath.path,
            "-package-name",
            "io",
            "-enable-experimental-feature",
            "LifetimeDependence",
            "-enable-experimental-feature",
            "Lifetimes",
            file.path,
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading
            .readDataToEndOfFile()

        return (
            status: process.terminationStatus,
            diagnostics: String(
                decoding: data,
                as: UTF8.self
            )
        )
    }
}
