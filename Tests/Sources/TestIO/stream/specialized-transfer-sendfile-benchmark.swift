import Dispatch
import Foundation
import IO

#if canImport(Darwin)
import Darwin
#endif

private enum SpecializedTransferLane: String, CaseIterable {
    case buffered_stream
    case sendfile
}

private struct SpecializedTransferSample {
    let nanoseconds: UInt64
    let transferredBytes: UInt64
    let receivedBytes: UInt64
    let transferCalls: UInt64
    let backendCalls: UInt64
    let unavailableCount: UInt64
}

private struct SpecializedTransferAggregate {
    let minimumNanoseconds: UInt64
    let medianNanoseconds: UInt64
    let maximumNanoseconds: UInt64
    let transferCalls: UInt64
    let backendCalls: UInt64
    let unavailableCount: UInt64
}

extension TestIO {
    static func runSpecializedTransferBenchmarks(
        heavy: Bool
    ) throws {
        #if canImport(Darwin)
        try runDarwinSpecializedTransferBenchmarks(
            heavy: heavy
        )
        #else
        print(
            "specialized transfer benchmark: Darwin sendfile unavailable"
        )
        #endif
    }
}

#if canImport(Darwin)
private extension TestIO {
    static func runDarwinSpecializedTransferBenchmarks(
        heavy: Bool
    ) throws {
        let capacity =
            try BufferCapacity(
                64 * 1024
            )
        let fullBytes =
            heavy
                ? 256 * 1024 * 1024
                : 64 * 1024 * 1024
        let boundedBytes =
            heavy
                ? 32 * 1024 * 1024
                : 8 * 1024 * 1024
        let samples =
            heavy
                ? 7
                : 5

        let root =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "io-specialized-transfer-\(UUID().uuidString)",
                    isDirectory: true
                )
        let sourceURL =
            root.appendingPathComponent(
                "source.bin"
            )

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: root
            )
        }

        try prepareSpecializedTransferFile(
            sourceURL,
            byteCount: fullBytes
        )

        print("specialized source->destination transfer")
        print("  A = production Source.stream(to:) -> Destination -> NonblockingSocketBackend")
        print("  K = Darwin sendfile(2) regular-file -> nonblocking stream socket")
        print("  receiver = raw nonblocking recv on the socketpair peer in both lanes")
        print("  source file cached across rotated samples")
        print("  endpoint construction/open/socketpair timed: false")
        print("  production buffer capacity: 64.00 KiB")
        print("  samples per lane: \(samples)")
        print("")

        let bounded =
            try collectSpecializedTransferSamples(
                samples: samples,
                expectedBytes: boundedBytes,
                buffered: {
                    try measureBufferedFileToSocket(
                        path: sourceURL.path,
                        expectedFileBytes: fullBytes,
                        maximumCount:
                            UInt64(
                                boundedBytes
                            ),
                        capacity: capacity
                    )
                },
                sendfile: {
                    try measureSendfileFileToSocket(
                        path: sourceURL.path,
                        expectedFileBytes: fullBytes,
                        maximumCount:
                            UInt64(
                                boundedBytes
                            )
                    )
                }
            )

        printSpecializedTransferRow(
            label:
                "bounded file->socket · \(formatSpecializedTransferBytes(boundedBytes))",
            aggregates: bounded
        )

        let full =
            try collectSpecializedTransferSamples(
                samples: samples,
                expectedBytes: fullBytes,
                buffered: {
                    try measureBufferedFileToSocket(
                        path: sourceURL.path,
                        expectedFileBytes: fullBytes,
                        maximumCount: nil,
                        capacity: capacity
                    )
                },
                sendfile: {
                    try measureSendfileFileToSocket(
                        path: sourceURL.path,
                        expectedFileBytes: fullBytes,
                        maximumCount: nil
                    )
                }
            )

        printSpecializedTransferRow(
            label:
                "to-EOF file->socket · \(formatSpecializedTransferBytes(fullBytes))",
            aggregates: full
        )

        print("interpretation:")
        print("  K materially faster -> specialized transfer deserves an optional stream fast path.")
        print("  K≈A -> keep the generic buffered stream path; kernel transfer adds little here.")
        print("  Any production integration must require empty Source/Destination staging before bypass.")
        print("  sendfile EAGAIN is progress-bearing: its returned len must advance logical transfer before retry.")
    }

    static func prepareSpecializedTransferFile(
        _ url: URL,
        byteCount: Int
    ) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil
        ) else {
            throw TestFailure(
                message:
                    "specialized-transfer benchmark could not create source fixture"
            )
        }

        let handle =
            try FileHandle(
                forWritingTo: url
            )
        defer {
            try? handle.close()
        }

        let chunkBytes =
            1024 * 1024
        let chunk =
            Data(
                repeating: 0x5a,
                count: chunkBytes
            )

        var written = 0
        while written < byteCount {
            let count =
                min(
                    chunkBytes,
                    byteCount - written
                )

            if count == chunkBytes {
                try handle.write(
                    contentsOf: chunk
                )
            } else {
                try handle.write(
                    contentsOf:
                        Data(
                            repeating: 0x5a,
                            count: count
                        )
                )
            }

            written += count
        }
    }

    static func measureBufferedFileToSocket(
        path: String,
        expectedFileBytes: Int,
        maximumCount: UInt64?,
        capacity: BufferCapacity
    ) throws -> SpecializedTransferSample {
        var descriptors =
            [Int32](
                repeating: -1,
                count: 2
            )

        guard makeSpecializedTransferSocketPair(
            &descriptors
        ) == 0 else {
            throw TestFailure(
                message:
                    "specialized-transfer production socketpair failed errno \(errno)"
            )
        }

        let sendingDescriptor =
            descriptors[0]
        let receivingDescriptor =
            descriptors[1]

        guard setSpecializedTransferNonblocking(
            receivingDescriptor
        ) else {
            _ = Darwin.close(
                sendingDescriptor
            )
            _ = Darwin.close(
                receivingDescriptor
            )
            throw TestFailure(
                message:
                    "specialized-transfer receiver nonblocking setup failed errno \(errno)"
            )
        }

        let sourceBackend: SystemFileSource
        do {
            sourceBackend =
                try SystemFileSource(
                    path: path
                )
        } catch {
            _ = Darwin.close(
                sendingDescriptor
            )
            _ = Darwin.close(
                receivingDescriptor
            )
            throw error
        }

        let destinationBackend: NonblockingSocketBackend
        do {
            destinationBackend =
                try NonblockingSocketBackend(
                    descriptor:
                        sendingDescriptor
                )
        } catch {
            _ = Darwin.close(
                sendingDescriptor
            )
            _ = Darwin.close(
                receivingDescriptor
            )
            throw error
        }

        defer {
            _ = Darwin.close(
                receivingDescriptor
            )
        }

        var source =
            Source(
                sourceBackend,
                bufferCapacity: capacity
            )
        var destination =
            Destination(
                destinationBackend,
                bufferCapacity: capacity
            )

        let targetBytes =
            maximumCount.map(Int.init)
            ?? expectedFileBytes

        var logicalTransferred:
            UInt64 = 0
        var received:
            UInt64 = 0
        var streamCalls:
            UInt64 = 0
        var unavailable:
            UInt64 = 0
        var sourceFinished = false
        var stagnant = 0
        var receiveStorage =
            [UInt8](
                repeating: 0,
                count: 64 * 1024
            )

        let start =
            DispatchTime.now()
                .uptimeNanoseconds

        while received
            < UInt64(
                targetBytes
            )
        {
            let beforeLogical =
                logicalTransferred
            let beforeReceived =
                received
            let beforeBuffered =
                destination
                    .bufferedByteCount

            if !sourceFinished {
                let result: StreamResult

                if let maximumCount {
                    let remaining =
                        maximumCount
                        - logicalTransferred

                    if remaining == 0 {
                        sourceFinished = true
                        result =
                            .limit(
                                transferred: 0
                            )
                    } else {
                        streamCalls += 1
                        result =
                            try source.stream(
                                to: &destination,
                                maximumCount:
                                    remaining
                            )
                    }
                } else {
                    streamCalls += 1
                    result =
                        try source.stream(
                            to: &destination
                        )
                }

                switch result {
                case .end(
                    let transferred
                ):
                    logicalTransferred +=
                        transferred
                    sourceFinished = true

                case .limit(
                    let transferred
                ):
                    logicalTransferred +=
                        transferred
                    if let maximumCount,
                       logicalTransferred
                        == maximumCount
                    {
                        sourceFinished = true
                    }

                case .destination_unavailable(
                    let transferred
                ):
                    logicalTransferred +=
                        transferred
                    unavailable += 1

                case .source_unavailable(
                    let transferred
                ):
                    logicalTransferred +=
                        transferred
                    unavailable += 1
                }
            }

            received +=
                try drainSpecializedTransferPeer(
                    receivingDescriptor,
                    storage:
                        &receiveStorage
                )

            if destination.bufferedByteCount
                > 0
            {
                switch try destination.flush() {
                case .complete:
                    break

                case .unavailable:
                    unavailable += 1
                }
            }

            received +=
                try drainSpecializedTransferPeer(
                    receivingDescriptor,
                    storage:
                        &receiveStorage
                )

            if logicalTransferred
                    == beforeLogical,
               received
                    == beforeReceived,
               destination.bufferedByteCount
                    == beforeBuffered
            {
                stagnant += 1

                if stagnant
                    > 1_000_000
                {
                    throw TestFailure(
                        message:
                            "specialized-transfer production lane stalled"
                    )
                }
            } else {
                stagnant = 0
            }
        }

        let elapsed =
            DispatchTime.now()
                .uptimeNanoseconds
            - start

        guard logicalTransferred
                == UInt64(
                    targetBytes
                )
        else {
            throw TestFailure(
                message:
                    "specialized-transfer production logical byte mismatch \(logicalTransferred) != \(targetBytes)"
            )
        }

        guard received
                == UInt64(
                    targetBytes
                )
        else {
            throw TestFailure(
                message:
                    "specialized-transfer production receive byte mismatch \(received) != \(targetBytes)"
            )
        }

        guard destination.bufferedByteCount
                == 0
        else {
            throw TestFailure(
                message:
                    "specialized-transfer production destination retained buffered bytes"
            )
        }

        return .init(
            nanoseconds:
                elapsed,
            transferredBytes:
                logicalTransferred,
            receivedBytes:
                received,
            transferCalls:
                streamCalls,
            backendCalls:
                source.statistics
                    .refillCallCount
                + destination.statistics
                    .drainCallCount,
            unavailableCount:
                unavailable
        )
    }

    static func measureSendfileFileToSocket(
        path: String,
        expectedFileBytes: Int,
        maximumCount: UInt64?
    ) throws -> SpecializedTransferSample {
        let fileDescriptor =
            path.withCString {
                Darwin.open(
                    $0,
                    O_RDONLY
                        | O_CLOEXEC
                )
            }

        guard fileDescriptor >= 0 else {
            throw TestFailure(
                message:
                    "specialized-transfer sendfile source open failed errno \(errno)"
            )
        }

        defer {
            _ = Darwin.close(
                fileDescriptor
            )
        }

        var descriptors =
            [Int32](
                repeating: -1,
                count: 2
            )

        guard makeSpecializedTransferSocketPair(
            &descriptors
        ) == 0 else {
            throw TestFailure(
                message:
                    "specialized-transfer sendfile socketpair failed errno \(errno)"
            )
        }

        let sendingDescriptor =
            descriptors[0]
        let receivingDescriptor =
            descriptors[1]

        defer {
            _ = Darwin.close(
                sendingDescriptor
            )
            _ = Darwin.close(
                receivingDescriptor
            )
        }

        guard setSpecializedTransferNonblocking(
            sendingDescriptor
        ),
              setSpecializedTransferNonblocking(
                receivingDescriptor
              )
        else {
            throw TestFailure(
                message:
                    "specialized-transfer sendfile nonblocking setup failed errno \(errno)"
            )
        }

        let targetBytes =
            maximumCount.map(Int.init)
            ?? expectedFileBytes

        var sent:
            UInt64 = 0
        var received:
            UInt64 = 0
        var sendfileCalls:
            UInt64 = 0
        var unavailable:
            UInt64 = 0
        var reachedEnd = false
        var stagnant = 0
        var receiveStorage =
            [UInt8](
                repeating: 0,
                count: 64 * 1024
            )

        let start =
            DispatchTime.now()
                .uptimeNanoseconds

        while received
            < UInt64(
                targetBytes
            )
        {
            let beforeSent =
                sent
            let beforeReceived =
                received

            if !reachedEnd,
               sent
                < UInt64(
                    targetBytes
                )
            {
                let remaining =
                    UInt64(
                        targetBytes
                    )
                    - sent

                var requested: off_t

                if maximumCount == nil {
                    requested = 0
                } else {
                    requested =
                        off_t(
                            remaining
                        )
                }

                sendfileCalls += 1
                errno = 0

                let result =
                    Darwin.sendfile(
                        fileDescriptor,
                        sendingDescriptor,
                        off_t(
                            sent
                        ),
                        &requested,
                        nil,
                        0
                    )

                if requested > 0 {
                    sent +=
                        UInt64(
                            requested
                        )
                }

                if result == 0 {
                    if maximumCount == nil {
                        reachedEnd = true
                    } else if sent
                        == UInt64(
                            targetBytes
                        )
                    {
                        reachedEnd = true
                    } else {
                        throw TestFailure(
                            message:
                                "specialized-transfer sendfile reached EOF before bounded target"
                        )
                    }
                } else {
                    let code =
                        errno

                    if code == EAGAIN
                        || code
                            == EWOULDBLOCK
                    {
                        unavailable += 1
                    } else if code
                        == EINTR
                    {
                        continue
                    } else {
                        throw TestFailure(
                            message:
                                "specialized-transfer sendfile failed errno \(code)"
                        )
                    }
                }
            }

            received +=
                try drainSpecializedTransferPeer(
                    receivingDescriptor,
                    storage:
                        &receiveStorage
                )

            if sent
                    == beforeSent,
               received
                    == beforeReceived
            {
                stagnant += 1

                if stagnant
                    > 1_000_000
                {
                    throw TestFailure(
                        message:
                            "specialized-transfer sendfile lane stalled"
                    )
                }
            } else {
                stagnant = 0
            }
        }

        let elapsed =
            DispatchTime.now()
                .uptimeNanoseconds
            - start

        guard sent
                == UInt64(
                    targetBytes
                )
        else {
            throw TestFailure(
                message:
                    "specialized-transfer sendfile logical byte mismatch \(sent) != \(targetBytes)"
            )
        }

        guard received
                == UInt64(
                    targetBytes
                )
        else {
            throw TestFailure(
                message:
                    "specialized-transfer sendfile receive byte mismatch \(received) != \(targetBytes)"
            )
        }

        return .init(
            nanoseconds:
                elapsed,
            transferredBytes:
                sent,
            receivedBytes:
                received,
            transferCalls:
                sendfileCalls,
            backendCalls:
                sendfileCalls,
            unavailableCount:
                unavailable
        )
    }

    static func drainSpecializedTransferPeer(
        _ descriptor: Int32,
        storage: inout [UInt8]
    ) throws -> UInt64 {
        var total:
            UInt64 = 0

        while true {
            let count =
                storage
                    .withUnsafeMutableBytes {
                        raw -> Int in

                        Darwin.recv(
                            descriptor,
                            raw.baseAddress,
                            raw.count,
                            0
                        )
                    }

            if count > 0 {
                let valid =
                    storage[
                        0..<count
                    ]
                    .allSatisfy {
                        $0 == 0x5a
                    }

                guard valid else {
                    throw TestFailure(
                        message:
                            "specialized-transfer receiver observed corrupted payload"
                    )
                }

                total +=
                    UInt64(
                        count
                    )
                continue
            }

            if count == 0 {
                throw TestFailure(
                    message:
                        "specialized-transfer peer closed before transfer completion"
                )
            }

            let code =
                errno

            if code == EAGAIN
                || code
                    == EWOULDBLOCK
            {
                return total
            }

            if code == EINTR {
                continue
            }

            throw TestFailure(
                message:
                    "specialized-transfer recv failed errno \(code)"
            )
        }
    }

    static func makeSpecializedTransferSocketPair(
        _ descriptors: inout [Int32]
    ) -> Int32 {
        descriptors
            .withUnsafeMutableBufferPointer {
                buffer in

                Darwin.socketpair(
                    AF_UNIX,
                    SOCK_STREAM,
                    0,
                    buffer.baseAddress
                )
            }
    }

    static func setSpecializedTransferNonblocking(
        _ descriptor: Int32
    ) -> Bool {
        let flags =
            Darwin.fcntl(
                descriptor,
                F_GETFL,
                0
            )

        guard flags >= 0 else {
            return false
        }

        return Darwin.fcntl(
            descriptor,
            F_SETFL,
            flags
                | O_NONBLOCK
        ) == 0
    }

    static func collectSpecializedTransferSamples(
        samples: Int,
        expectedBytes: Int,
        buffered:
            () throws -> SpecializedTransferSample,
        sendfile:
            () throws -> SpecializedTransferSample
    ) throws -> (
        buffered: SpecializedTransferAggregate,
        sendfile: SpecializedTransferAggregate
    ) {
        var bufferedSamples:
            [SpecializedTransferSample] = []
        var sendfileSamples:
            [SpecializedTransferSample] = []

        for index in 0..<samples {
            if index.isMultiple(
                of: 2
            ) {
                bufferedSamples.append(
                    try buffered()
                )
                sendfileSamples.append(
                    try sendfile()
                )
            } else {
                sendfileSamples.append(
                    try sendfile()
                )
                bufferedSamples.append(
                    try buffered()
                )
            }
        }

        for sample in bufferedSamples
            + sendfileSamples
        {
            guard sample.transferredBytes
                    == UInt64(
                        expectedBytes
                    ),
                  sample.receivedBytes
                    == UInt64(
                        expectedBytes
                    )
            else {
                throw TestFailure(
                    message:
                        "specialized-transfer lanes performed unequal logical work"
                )
            }
        }

        return (
            aggregateSpecializedTransferSamples(
                bufferedSamples
            ),
            aggregateSpecializedTransferSamples(
                sendfileSamples
            )
        )
    }

    static func aggregateSpecializedTransferSamples(
        _ samples:
            [SpecializedTransferSample]
    ) -> SpecializedTransferAggregate {
        let timings =
            samples
                .map(
                    \.nanoseconds
                )
                .sorted()
        let median =
            timings[
                timings.count / 2
            ]

        let representative =
            samples.min {
                specializedTransferDistance(
                    $0.nanoseconds,
                    median
                )
                    < specializedTransferDistance(
                        $1.nanoseconds,
                        median
                    )
            }
            ?? samples[0]

        return .init(
            minimumNanoseconds:
                timings.first
                ?? median,
            medianNanoseconds:
                median,
            maximumNanoseconds:
                timings.last
                ?? median,
            transferCalls:
                representative
                    .transferCalls,
            backendCalls:
                representative
                    .backendCalls,
            unavailableCount:
                representative
                    .unavailableCount
        )
    }

    static func printSpecializedTransferRow(
        label: String,
        aggregates: (
            buffered: SpecializedTransferAggregate,
            sendfile: SpecializedTransferAggregate
        )
    ) {
        let timeRatio =
            Double(
                aggregates.sendfile
                    .medianNanoseconds
            )
            / Double(
                aggregates.buffered
                    .medianNanoseconds
            )
        let speedup =
            Double(
                aggregates.buffered
                    .medianNanoseconds
            )
            / Double(
                aggregates.sendfile
                    .medianNanoseconds
            )

        print(label)
        print(
            "  A buffered_stream "
            + formatSpecializedTransferTiming(
                aggregates.buffered
            )
        )
        print(
            "  K sendfile "
            + formatSpecializedTransferTiming(
                aggregates.sendfile
            )
        )
        print(
            String(
                format:
                    "  K/A time %.3fx · kernel speedup %.3fx",
                timeRatio,
                speedup
            )
        )
        print(
            "  transfer calls A/K "
            + "\(aggregates.buffered.transferCalls)/\(aggregates.sendfile.transferCalls)"
            + " · backend/syscalls "
            + "\(aggregates.buffered.backendCalls)/\(aggregates.sendfile.backendCalls)"
            + " · unavailable/EAGAIN "
            + "\(aggregates.buffered.unavailableCount)/\(aggregates.sendfile.unavailableCount)"
        )
        print("")
    }

    static func formatSpecializedTransferTiming(
        _ aggregate:
            SpecializedTransferAggregate
    ) -> String {
        "\(formatSpecializedTransferMilliseconds(aggregate.medianNanoseconds))"
            + " [\(formatSpecializedTransferMilliseconds(aggregate.minimumNanoseconds))"
            + "…\(formatSpecializedTransferMilliseconds(aggregate.maximumNanoseconds))]"
    }

    static func formatSpecializedTransferMilliseconds(
        _ nanoseconds: UInt64
    ) -> String {
        String(
            format:
                "%.3f ms",
            Double(
                nanoseconds
            )
                / 1_000_000.0
        )
    }

    static func formatSpecializedTransferBytes(
        _ bytes: Int
    ) -> String {
        if bytes
            >= 1024 * 1024
        {
            return String(
                format:
                    "%.2f MiB",
                Double(
                    bytes
                )
                    / Double(
                        1024 * 1024
                    )
            )
        }

        return String(
            format:
                "%.2f KiB",
            Double(
                bytes
            )
                / 1024.0
        )
    }

    static func specializedTransferDistance(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        lhs >= rhs
            ? lhs - rhs
            : rhs - lhs
    }
}
#endif
