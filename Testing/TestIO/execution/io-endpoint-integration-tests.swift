import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private enum EndpointRuntimeVariant:
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

extension TestIO {
    static func testIOSocketSourceRuntimeMatrix()
        async throws
    {
        for variant
            in EndpointRuntimeVariant.allCases
        {
            try await runSocketSourceFixture(
                variant
            )
        }
    }

    static func testIOSocketDestinationWriteRuntimeMatrix()
        async throws
    {
        for variant
            in EndpointRuntimeVariant.allCases
        {
            try await runSocketDestinationWriteFixture(
                variant
            )
        }
    }

    static func testIOSocketDestinationFlushRuntimeMatrix()
        async throws
    {
        for variant
            in EndpointRuntimeVariant.allCases
        {
            try await runSocketDestinationFlushFixture(
                variant
            )
        }
    }

    static func testIOSocketSourceDeadline()
        async throws
    {
        let runtime =
            try EventedIORuntime()
        defer {
            runtime.shutdown()
        }

        var pair =
            [Int32](
                repeating: -1,
                count: 2
            )

        guard makeEndpointSocketPair(
            &pair
        ) == 0
        else {
            throw TestFailure(
                message:
                    "E3 source deadline socketpair failed with errno \(errno)"
            )
        }

        let readDescriptor =
            pair[0]
        let peerDescriptor =
            pair[1]

        defer {
            closeEndpointDescriptor(
                readDescriptor
            )
            closeEndpointDescriptor(
                peerDescriptor
            )
        }

        var source =
            Source(
                try NonblockingSocketBackend(
                    descriptor:
                        readDescriptor,
                    ownsDescriptor:
                        false
                ),
                bufferCapacity:
                    try BufferCapacity(
                        32
                    )
            )

        let io =
            IO(
                runtime
            )

        do {
            _ =
                try await source.prepare(
                    io: io,
                    deadline:
                        io.deadline(
                            after:
                                .init(
                                    nanoseconds:
                                        5_000_000
                                )
                        )
                )

            throw TestFailure(
                message:
                    "E3 source deadline unexpectedly completed"
            )
        } catch let error
            as IOExecutionError
        {
            guard error
                    == .timed_out
            else {
                throw TestFailure(
                    message:
                        "E3 source deadline returned \(error), expected timed_out"
                )
            }
        }
    }

    private static func runSocketSourceFixture(
        _ variant:
            EndpointRuntimeVariant
    ) async throws {
        switch variant {
        case .blocking:
            let runtime =
                BlockingIORuntime()

            try await exerciseSocketSource(
                io:
                    IO(
                        runtime
                    ),
                label:
                    variant.label
            )

        case .evented:
            let runtime =
                try EventedIORuntime()
            defer {
                runtime.shutdown()
            }

            try await exerciseSocketSource(
                io:
                    IO(
                        runtime
                    ),
                label:
                    variant.label
            )

        case .evented_workers:
            let runtime =
                try EventedIORuntime(
                    workerCount: 2
                )
            defer {
                runtime.shutdown()
            }

            try await exerciseSocketSource(
                io:
                    IO(
                        runtime
                    ),
                label:
                    variant.label
            )
        }
    }

    private static func exerciseSocketSource(
        io: IO,
        label: String
    ) async throws {
        var pair =
            [Int32](
                repeating: -1,
                count: 2
            )

        guard makeEndpointSocketPair(
            &pair
        ) == 0
        else {
            throw TestFailure(
                message:
                    "\(label): source socketpair failed with errno \(errno)"
            )
        }

        let readDescriptor =
            pair[0]
        let writeDescriptor =
            pair[1]

        defer {
            closeEndpointDescriptor(
                readDescriptor
            )
            closeEndpointDescriptor(
                writeDescriptor
            )
        }

        var source =
            Source(
                try NonblockingSocketBackend(
                    descriptor:
                        readDescriptor,
                    ownsDescriptor:
                        false
                ),
                bufferCapacity:
                    try BufferCapacity(
                        8
                    )
            )

        guard try source.prepare()
                == .unavailable
        else {
            throw TestFailure(
                message:
                    "\(label): source did not expose initial backpressure"
            )
        }

        let payload:
            [UInt8] = [
                1, 2, 3, 4,
                5, 6, 7, 8,
                9, 10, 11, 12,
            ]

        let writer =
            Task.detached {
                try writeEndpointBytes(
                    descriptor:
                        writeDescriptor,
                    bytes:
                        payload
                )
            }

        var received:
            [UInt8] = []

        while received.count
                < payload.count
        {
            let availability =
                try await source.prepare(
                    io: io,
                    deadline:
                        io.deadline(
                            after:
                                .init(
                                    seconds: 1
                                )
                        )
                )

            guard availability
                    == .bytes
            else {
                throw TestFailure(
                    message:
                        "\(label): source returned \(availability) before payload completed"
                )
            }

            let chunk =
                source.withReadableRegions {
                    first,
                    second in

                    Array(
                        first
                    )
                    + Array(
                        second
                    )
                }

            guard !chunk.isEmpty else {
                throw TestFailure(
                    message:
                        "\(label): source reported bytes with an empty buffer"
                )
            }

            received.append(
                contentsOf:
                    chunk
            )

            try source.consume(
                chunk.count
            )
        }

        try await writer.value

        guard received
                == payload
        else {
            throw TestFailure(
                message:
                    "\(label): source payload mismatch \(received)"
            )
        }
    }

    private static func runSocketDestinationWriteFixture(
        _ variant:
            EndpointRuntimeVariant
    ) async throws {
        switch variant {
        case .blocking:
            try await exerciseSocketDestinationWrite(
                io:
                    IO(
                        BlockingIORuntime()
                    ),
                label:
                    variant.label
            )

        case .evented:
            let runtime =
                try EventedIORuntime()
            defer {
                runtime.shutdown()
            }

            try await exerciseSocketDestinationWrite(
                io:
                    IO(
                        runtime
                    ),
                label:
                    variant.label
            )

        case .evented_workers:
            let runtime =
                try EventedIORuntime(
                    workerCount: 2
                )
            defer {
                runtime.shutdown()
            }

            try await exerciseSocketDestinationWrite(
                io:
                    IO(
                        runtime
                    ),
                label:
                    variant.label
            )
        }
    }

    private static func exerciseSocketDestinationWrite(
        io: IO,
        label: String
    ) async throws {
        var pair =
            [Int32](
                repeating: -1,
                count: 2
            )

        guard makeEndpointSocketPair(
            &pair
        ) == 0
        else {
            throw TestFailure(
                message:
                    "\(label): destination-write socketpair failed with errno \(errno)"
            )
        }

        let writeDescriptor =
            pair[0]
        let readDescriptor =
            pair[1]

        defer {
            closeEndpointDescriptor(
                writeDescriptor
            )
            closeEndpointDescriptor(
                readDescriptor
            )
        }

        let backend =
            try NonblockingSocketBackend(
                descriptor:
                    writeDescriptor,
                ownsDescriptor:
                    false
            )

        fillEndpointSocket(
            descriptor:
                writeDescriptor
        )

        var destination =
            Destination(
                backend,
                bufferCapacity:
                    try BufferCapacity(
                        1
                    )
            )

        let marker:
            [UInt8] = [
                0xA1,
                0xA2,
            ]

        guard try destination.write(
            marker
        ) == .unavailable
        else {
            throw TestFailure(
                message:
                    "\(label): direct destination write did not expose saturated-socket backpressure"
            )
        }

        let reader =
            Task.detached {
                try readEndpointUntilMarker(
                    descriptor:
                        readDescriptor,
                    marker:
                        marker
                )
            }

        let result =
            try await destination.write(
                marker,
                io: io,
                deadline:
                    io.deadline(
                        after:
                            .init(
                                seconds: 1
                            )
                    )
            )

        guard result
                == .complete
        else {
            throw TestFailure(
                message:
                    "\(label): async destination write returned \(result)"
            )
        }

        guard try await reader.value else {
            throw TestFailure(
                message:
                    "\(label): peer did not observe async destination marker"
            )
        }
    }

    private static func runSocketDestinationFlushFixture(
        _ variant:
            EndpointRuntimeVariant
    ) async throws {
        switch variant {
        case .blocking:
            try await exerciseSocketDestinationFlush(
                io:
                    IO(
                        BlockingIORuntime()
                    ),
                label:
                    variant.label
            )

        case .evented:
            let runtime =
                try EventedIORuntime()
            defer {
                runtime.shutdown()
            }

            try await exerciseSocketDestinationFlush(
                io:
                    IO(
                        runtime
                    ),
                label:
                    variant.label
            )

        case .evented_workers:
            let runtime =
                try EventedIORuntime(
                    workerCount: 2
                )
            defer {
                runtime.shutdown()
            }

            try await exerciseSocketDestinationFlush(
                io:
                    IO(
                        runtime
                    ),
                label:
                    variant.label
            )
        }
    }

    private static func exerciseSocketDestinationFlush(
        io: IO,
        label: String
    ) async throws {
        var pair =
            [Int32](
                repeating: -1,
                count: 2
            )

        guard makeEndpointSocketPair(
            &pair
        ) == 0
        else {
            throw TestFailure(
                message:
                    "\(label): destination-flush socketpair failed with errno \(errno)"
            )
        }

        let writeDescriptor =
            pair[0]
        let readDescriptor =
            pair[1]

        defer {
            closeEndpointDescriptor(
                writeDescriptor
            )
            closeEndpointDescriptor(
                readDescriptor
            )
        }

        let backend =
            try NonblockingSocketBackend(
                descriptor:
                    writeDescriptor,
                ownsDescriptor:
                    false
            )

        fillEndpointSocket(
            descriptor:
                writeDescriptor
        )

        var destination =
            Destination(
                backend,
                bufferCapacity:
                    try BufferCapacity(
                        1
                    )
            )

        guard try destination.write(
            UInt8(
                0xB1
            )
        ) == .complete
        else {
            throw TestFailure(
                message:
                    "\(label): one-byte staging write failed"
            )
        }

        guard try destination.flush()
                == .unavailable
        else {
            throw TestFailure(
                message:
                    "\(label): synchronous flush did not expose backpressure"
            )
        }

        let reader =
            Task.detached {
                try readEndpointUntilMarker(
                    descriptor:
                        readDescriptor,
                    marker:
                        [0xB1]
                )
            }

        let result =
            try await destination.flush(
                io: io,
                deadline:
                    io.deadline(
                        after:
                            .init(
                                seconds: 1
                            )
                    )
            )

        guard result
                == .complete
        else {
            throw TestFailure(
                message:
                    "\(label): async flush returned \(result)"
            )
        }

        guard try await reader.value else {
            throw TestFailure(
                message:
                    "\(label): peer did not observe flushed marker"
            )
        }
    }
}

private func makeEndpointSocketPair(
    _ descriptors:
        inout [Int32]
) -> Int32 {
    descriptors
        .withUnsafeMutableBufferPointer {
            buffer in

            #if canImport(Darwin)
            Darwin.socketpair(
                AF_UNIX,
                SOCK_STREAM,
                0,
                buffer.baseAddress
            )
            #elseif canImport(Glibc)
            Glibc.socketpair(
                AF_UNIX,
                Int32(
                    SOCK_STREAM.rawValue
                ),
                0,
                buffer.baseAddress
            )
            #endif
        }
}

private func closeEndpointDescriptor(
    _ descriptor: Int32
) {
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

private func writeEndpointBytes(
    descriptor: Int32,
    bytes: [UInt8]
) throws {
    var offset =
        0

    while offset
            < bytes.count
    {
        let written =
            bytes.withUnsafeBytes {
                raw in

                let pointer =
                    raw.baseAddress?
                        .advanced(
                            by:
                                offset
                        )

                #if canImport(Darwin)
                return Darwin.send(
                    descriptor,
                    pointer,
                    raw.count
                        - offset,
                    0
                )
                #elseif canImport(Glibc)
                return Glibc.send(
                    descriptor,
                    pointer,
                    raw.count
                        - offset,
                    Int32(
                        MSG_NOSIGNAL
                    )
                )
                #endif
            }

        if written > 0 {
            offset +=
                written
            continue
        }

        if written < 0
            && errno == EINTR
        {
            continue
        }

        throw TestFailure(
            message:
                "E3 peer write failed with errno \(errno)"
        )
    }
}

private func fillEndpointSocket(
    descriptor: Int32
) {
    let bytes =
        [UInt8](
            repeating:
                0x5A,
            count:
                4_096
        )

    while true {
        let result =
            bytes.withUnsafeBytes {
                raw in

                #if canImport(Darwin)
                return Darwin.send(
                    descriptor,
                    raw.baseAddress,
                    raw.count,
                    0
                )
                #elseif canImport(Glibc)
                return Glibc.send(
                    descriptor,
                    raw.baseAddress,
                    raw.count,
                    Int32(
                        MSG_NOSIGNAL
                    )
                )
                #endif
            }

        if result > 0 {
            continue
        }

        if result < 0
            && errno == EINTR
        {
            continue
        }

        if result < 0
            && (
                errno == EAGAIN
                || errno == EWOULDBLOCK
            )
        {
            return
        }

        return
    }
}

private func readEndpointUntilMarker(
    descriptor: Int32,
    marker: [UInt8]
) throws -> Bool {
    precondition(
        !marker.isEmpty
    )

    var matched =
        0
    var storage =
        [UInt8](
            repeating: 0,
            count: 4_096
        )

    while true {
        let count =
            storage.withUnsafeMutableBytes {
                raw in

                #if canImport(Darwin)
                return Darwin.recv(
                    descriptor,
                    raw.baseAddress,
                    raw.count,
                    0
                )
                #elseif canImport(Glibc)
                return Glibc.recv(
                    descriptor,
                    raw.baseAddress,
                    raw.count,
                    0
                )
                #endif
            }

        if count > 0 {
            for byte
                in storage.prefix(
                    count
                )
            {
                if byte
                    == marker[
                        matched
                    ]
                {
                    matched += 1

                    if matched
                        == marker.count
                    {
                        return true
                    }
                } else {
                    matched =
                        byte
                            == marker[0]
                        ? 1
                        : 0
                }
            }

            continue
        }

        if count == 0 {
            return false
        }

        if errno == EINTR {
            continue
        }

        throw TestFailure(
            message:
                "E3 peer read failed with errno \(errno)"
        )
    }
}
