import Dispatch
import Foundation
import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private enum FileRuntimeVariant:
    CaseIterable,
    Sendable
{
    case blocking
    case evented
    case evented_workers

    var label: String {
        switch self {
        case .blocking:
            "blocking"
        case .evented:
            "evented"
        case .evented_workers:
            "evented-workers"
        }
    }
}

private struct FileTransferObservation:
    Sendable,
    Equatable
{
    let result:
        StreamResult
    let flush:
        DestinationFlush
    let bytes:
        [UInt8]
}

private struct FileReadObservation:
    Sendable,
    Equatable
{
    let availability:
        SourceAvailability
    let bytes:
        [UInt8]
}

extension TestIO {
    static func testIOFileTransferRuntimeMatrix()
        async throws
    {
        for variant
            in FileRuntimeVariant.allCases
        {
            try await runFileTransferFixture(
                variant
            )
        }
    }

    static func testIOFileWorkerReactorIsolation()
        async throws
    {
        let runtime =
            try EventedIORuntime(
                workerCount: 1
            )
        defer {
            runtime.shutdown()
        }

        let io =
            IO(
                runtime
            )

        let fifoPath =
            temporaryExecutionPath(
                name:
                    "blocking-file-fifo"
            )

        defer {
            try? FileManager.default.removeItem(
                atPath:
                    fifoPath
            )
        }

        guard makeExecutionFIFO(
            path:
                fifoPath
        ) == 0
        else {
            throw TestFailure(
                message:
                    "E3b mkfifo failed with errno \(errno)"
            )
        }

        let started =
            DispatchSemaphore(
                value: 0
            )

        let reader =
            Task.detached {
                try await io.runBlocking {
                    started.signal()

                    var source =
                        Source(
                            try SystemFileSource(
                                path:
                                    fifoPath
                            ),
                            bufferCapacity:
                                try BufferCapacity(
                                    16
                                )
                        )

                    let availability =
                        try source.prepare()

                    let bytes =
                        source.withBytes {
                            Array(
                                $0
                            )
                        }

                    return FileReadObservation(
                        availability:
                            availability,
                        bytes:
                            bytes
                    )
                }
            }

        let writer =
            Task.detached {
                sleepExecutionMicroseconds(
                    250_000
                )

                try writeExecutionFIFOByte(
                    path:
                        fifoPath,
                    byte:
                        0xD3
                )
            }

        let workerStarted =
            await waitExecutionSemaphore(
                started,
                timeoutSeconds:
                    1.0
            )

        guard workerStarted else {
            throw TestFailure(
                message:
                    "E3b blocking file worker did not start"
            )
        }

        let before =
            DispatchTime
                .now()
                .uptimeNanoseconds

        try await io.sleep(
            for:
                .init(
                    nanoseconds:
                        5_000_000
                )
        )

        let after =
            DispatchTime
                .now()
                .uptimeNanoseconds

        let elapsed =
            after - before

        guard elapsed
                < 100_000_000
        else {
            throw TestFailure(
                message:
                    "E3b reactor timer stalled behind blocking file work: \(elapsed) ns"
            )
        }

        let observation =
            try await reader.value

        try await writer.value

        guard observation.availability
                == .bytes
        else {
            throw TestFailure(
                message:
                    "E3b FIFO source returned \(observation.availability)"
            )
        }

        guard observation.bytes
                == [0xD3]
        else {
            throw TestFailure(
                message:
                    "E3b FIFO source returned \(observation.bytes)"
            )
        }
    }

    private static func runFileTransferFixture(
        _ variant:
            FileRuntimeVariant
    ) async throws {
        let sourcePath =
            temporaryExecutionPath(
                name:
                    "file-source-\(variant.label)"
            )
        let destinationPath =
            temporaryExecutionPath(
                name:
                    "file-destination-\(variant.label)"
            )

        defer {
            try? FileManager.default.removeItem(
                atPath:
                    sourcePath
            )
            try? FileManager.default.removeItem(
                atPath:
                    destinationPath
            )
        }

        let payload =
            executionFilePayload(
                byteCount:
                    131_071
            )

        try Data(
            payload
        ).write(
            to:
                URL(
                    fileURLWithPath:
                        sourcePath
                )
        )

        let observation:
            FileTransferObservation

        switch variant {
        case .blocking:
            observation =
                try await runFileTransfer(
                    io:
                        IO.blocking,
                    sourcePath:
                        sourcePath,
                    destinationPath:
                        destinationPath
                )

        case .evented:
            let runtime =
                try EventedIORuntime()
            defer {
                runtime.shutdown()
            }

            observation =
                try await runFileTransfer(
                    io:
                        IO(
                            runtime
                        ),
                    sourcePath:
                        sourcePath,
                    destinationPath:
                        destinationPath
                )

        case .evented_workers:
            let runtime =
                try EventedIORuntime(
                    workerCount: 2
                )
            defer {
                runtime.shutdown()
            }

            observation =
                try await runFileTransfer(
                    io:
                        IO(
                            runtime
                        ),
                    sourcePath:
                        sourcePath,
                    destinationPath:
                        destinationPath
                )
        }

        guard observation.result
                == .end(
                    transferred:
                        UInt64(
                            payload.count
                        )
                )
        else {
            throw TestFailure(
                message:
                    "\(variant.label): E3b file transfer returned \(observation.result)"
            )
        }

        guard observation.flush
                == .complete
        else {
            throw TestFailure(
                message:
                    "\(variant.label): E3b file flush returned \(observation.flush)"
            )
        }

        guard observation.bytes
                == payload
        else {
            throw TestFailure(
                message:
                    "\(variant.label): E3b file transfer payload mismatch"
            )
        }
    }

    private static func runFileTransfer(
        io: IO,
        sourcePath: String,
        destinationPath: String
    ) async throws
        -> FileTransferObservation
    {
        try await io.runBlocking {
            var source =
                Source(
                    try SystemFileSource(
                        path:
                            sourcePath
                    ),
                    bufferCapacity:
                        try BufferCapacity(
                            8_191
                        )
                )

            var destination =
                Destination(
                    try SystemFileDestination(
                        path:
                            destinationPath,
                        mode:
                            .truncate
                    ),
                    bufferCapacity:
                        try BufferCapacity(
                            6_143
                        )
                )

            let result =
                try source.stream(
                    to:
                        &destination
                )

            let flush =
                try destination.flush()

            let bytes =
                Array(
                    try Data(
                        contentsOf:
                            URL(
                                fileURLWithPath:
                                    destinationPath
                            )
                    )
                )

            return FileTransferObservation(
                result:
                    result,
                flush:
                    flush,
                bytes:
                    bytes
            )
        }
    }

    private static func executionFilePayload(
        byteCount: Int
    ) -> [UInt8] {
        (0..<byteCount).map {
            index in

            UInt8(
                truncatingIfNeeded:
                    index &* 31
                    &+ index / 7
            )
        }
    }

    private static func temporaryExecutionPath(
        name: String
    ) -> String {
        FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "tio-\(name)-\(UUID().uuidString)"
            )
            .path
    }
}

private func waitExecutionSemaphore(
    _ semaphore: DispatchSemaphore,
    timeoutSeconds: Double
) async -> Bool {
    await withCheckedContinuation {
        continuation in

        DispatchQueue.global(
            qos: .userInitiated
        ).async {
            continuation.resume(
                returning:
                    semaphore.wait(
                        timeout:
                            .now()
                            + timeoutSeconds
                    ) == .success
            )
        }
    }
}

private func makeExecutionFIFO(
    path: String
) -> Int32 {
    path.withCString {
        pointer in

        #if canImport(Darwin)
        Darwin.mkfifo(
            pointer,
            mode_t(
                0o600
            )
        )
        #elseif canImport(Glibc)
        Glibc.mkfifo(
            pointer,
            mode_t(
                0o600
            )
        )
        #endif
    }
}

private func sleepExecutionMicroseconds(
    _ microseconds: UInt32
) {
    #if canImport(Darwin)
    _ =
        Darwin.usleep(
            microseconds
        )
    #elseif canImport(Glibc)
    _ =
        Glibc.usleep(
            microseconds
        )
    #endif
}

private func writeExecutionFIFOByte(
    path: String,
    byte: UInt8
) throws {
    let descriptor =
        path.withCString {
            pointer in

            #if canImport(Darwin)
            Darwin.open(
                pointer,
                O_WRONLY
            )
            #elseif canImport(Glibc)
            Glibc.open(
                pointer,
                O_WRONLY
            )
            #endif
        }

    guard descriptor >= 0 else {
        throw TestFailure(
            message:
                "E3b FIFO writer open failed with errno \(errno)"
        )
    }

    defer {
        #if canImport(Darwin)
        _ =
            Darwin.close(
                descriptor
            )
        #elseif canImport(Glibc)
        _ =
            Glibc.close(
                descriptor
            )
        #endif
    }

    var value =
        byte

    while true {
        let result =
            withUnsafeBytes(
                of:
                    &value
            ) {
                raw in

                #if canImport(Darwin)
                Darwin.write(
                    descriptor,
                    raw.baseAddress,
                    raw.count
                )
                #elseif canImport(Glibc)
                Glibc.write(
                    descriptor,
                    raw.baseAddress,
                    raw.count
                )
                #endif
            }

        if result == 1 {
            return
        }

        if result < 0
            && errno == EINTR
        {
            continue
        }

        throw TestFailure(
            message:
                "E3b FIFO writer write failed with errno \(errno)"
        )
    }
}
