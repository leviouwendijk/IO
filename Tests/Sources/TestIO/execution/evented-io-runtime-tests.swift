import Dispatch
import Foundation
import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private enum EventedIOTestError:
    Error,
    Sendable
{
    case worker_barrier_timed_out
}

extension TestIO {
    static func testIOEventedReadiness()
        async throws
    {
        var descriptors:
            [Int32] = [0, 0]
        try makeExecutionPipe(
            &descriptors
        )

        defer {
            closeExecutionDescriptor(
                descriptors[0]
            )
            closeExecutionDescriptor(
                descriptors[1]
            )
        }

        let runtime =
            try EventedIORuntime()
        defer {
            runtime.shutdown()
        }

        let io =
            IO(
                runtime
            )

        let readDescriptor =
            descriptors[0]

        let waiter =
            Task {
                try await io.wait(
                    descriptor:
                        readDescriptor,
                    for:
                        .readable,
                    deadline:
                        io.deadline(
                            after:
                                .init(
                                    seconds: 1
                                )
                        )
                )
            }

        try await io.sleep(
            for:
                .init(
                    nanoseconds:
                        2_000_000
                )
        )

        try writeExecutionByte(
            descriptor:
                descriptors[1],
            byte:
                0xA5
        )

        try await waiter.value
    }

    static func testIOEventedDeadline()
        async throws
    {
        var descriptors:
            [Int32] = [0, 0]
        try makeExecutionPipe(
            &descriptors
        )

        defer {
            closeExecutionDescriptor(
                descriptors[0]
            )
            closeExecutionDescriptor(
                descriptors[1]
            )
        }

        let runtime =
            try EventedIORuntime()
        defer {
            runtime.shutdown()
        }

        let io =
            IO(
                runtime
            )

        do {
            try await io.wait(
                descriptor:
                    descriptors[0],
                for:
                    .readable,
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
                    "evented wait unexpectedly completed without readiness"
            )
        } catch let error
            as IOExecutionError
        {
            guard error
                    == .timed_out
            else {
                throw TestFailure(
                    message:
                        "evented deadline returned \(error), expected timed_out"
                )
            }
        }
    }

    static func testIOEventedCancellationWakeup()
        async throws
    {
        var descriptors:
            [Int32] = [0, 0]
        try makeExecutionPipe(
            &descriptors
        )

        defer {
            closeExecutionDescriptor(
                descriptors[0]
            )
            closeExecutionDescriptor(
                descriptors[1]
            )
        }

        let runtime =
            try EventedIORuntime()
        defer {
            runtime.shutdown()
        }

        let io =
            IO(
                runtime
            )

        let readDescriptor =
            descriptors[0]

        let waiter =
            Task {
                try await io.wait(
                    descriptor:
                        readDescriptor,
                    for:
                        .readable
                )
            }

        try await io.sleep(
            for:
                .init(
                    nanoseconds:
                        2_000_000
                )
        )

        waiter.cancel()

        do {
            try await waiter.value

            throw TestFailure(
                message:
                    "cancelled evented wait unexpectedly succeeded"
            )
        } catch is CancellationError {
            // Active cancellation removes the registration and wakes the reactor.
        }
    }

    static func testIOEventedManyWaiters()
        async throws
    {
        let runtime =
            try EventedIORuntime()
        defer {
            runtime.shutdown()
        }

        let io =
            IO(
                runtime
            )

        var pipes:
            [(Int32, Int32)] = []
        var waiters:
            [Task<Void, Error>] = []

        defer {
            for pair
                in pipes
            {
                closeExecutionDescriptor(
                    pair.0
                )
                closeExecutionDescriptor(
                    pair.1
                )
            }
        }

        for _ in 0..<32 {
            var descriptors:
                [Int32] = [0, 0]
            try makeExecutionPipe(
                &descriptors
            )

            pipes.append(
                (
                    descriptors[0],
                    descriptors[1]
                )
            )

            let readDescriptor =
                descriptors[0]

            waiters.append(
                Task {
                    try await io.wait(
                        descriptor:
                            readDescriptor,
                        for:
                            .readable,
                        deadline:
                            io.deadline(
                                after:
                                    .init(
                                        seconds: 1
                                    )
                            )
                    )
                }
            )
        }

        try await io.sleep(
            for:
                .init(
                    nanoseconds:
                        2_000_000
                )
        )

        for (
            index,
            pair
        ) in pipes.enumerated()
        {
            try writeExecutionByte(
                descriptor:
                    pair.1,
                byte:
                    UInt8(
                        truncatingIfNeeded:
                            index
                    )
            )
        }

        for waiter
            in waiters
        {
            try await waiter.value
        }
    }

    static func testIOEventedWorkerConcurrency()
        async throws
    {
        let runtime =
            try EventedIORuntime(
                workerCount: 2
            )
        defer {
            runtime.shutdown()
        }

        let io =
            IO(
                runtime
            )

        let firstStarted =
            DispatchSemaphore(
                value: 0
            )
        let secondStarted =
            DispatchSemaphore(
                value: 0
            )

        let first =
            Task {
                try await io.runBlocking {
                    firstStarted.signal()

                    guard secondStarted.wait(
                        timeout:
                            .now() + 2.0
                    ) == .success
                    else {
                        throw EventedIOTestError
                            .worker_barrier_timed_out
                    }

                    return 1
                }
            }

        let second =
            Task {
                try await io.runBlocking {
                    secondStarted.signal()

                    guard firstStarted.wait(
                        timeout:
                            .now() + 2.0
                    ) == .success
                    else {
                        throw EventedIOTestError
                            .worker_barrier_timed_out
                    }

                    return 2
                }
            }

        let firstValue =
            try await first.value
        let secondValue =
            try await second.value

        guard firstValue == 1,
            secondValue == 2
        else {
            throw TestFailure(
                message:
                    "evented worker lane returned unexpected values"
            )
        }
    }

    static func testIOEventedReactorResponsiveDuringWorkerBlock()
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
        let started =
            DispatchSemaphore(
                value: 0
            )
        let release =
            DispatchSemaphore(
                value: 0
            )

        let worker =
            Task {
                try await io.runBlocking {
                    started.signal()

                    _ = release.wait(
                        timeout:
                            .now() + 1.0
                    )

                    return 82
                }
            }

        let workerStarted: Bool =
            await withCheckedContinuation {
                continuation in

                DispatchQueue.global(
                    qos: .userInitiated
                ).async {
                    continuation.resume(
                        returning:
                            started.wait(
                                timeout:
                                    .now() + 1.0
                            ) == .success
                    )
                }
            }

        guard workerStarted else {
            throw TestFailure(
                message:
                    "blocking worker did not start"
            )
        }

        let before =
            runtime
                .monotonicNanoseconds()

        try await io.sleep(
            for:
                .init(
                    nanoseconds:
                        5_000_000
                )
        )

        let after =
            runtime
                .monotonicNanoseconds()

        release.signal()

        guard try await worker.value
                == 82
        else {
            throw TestFailure(
                message:
                    "blocking worker returned unexpected value"
            )
        }

        let elapsed =
            after - before

        guard elapsed
                < 250_000_000
        else {
            throw TestFailure(
                message:
                    "reactor timer was stalled by worker for \(elapsed)ns"
            )
        }
    }

    static func testIOEventedShutdownPendingWait()
        async throws
    {
        var descriptors:
            [Int32] = [0, 0]
        try makeExecutionPipe(
            &descriptors
        )

        defer {
            closeExecutionDescriptor(
                descriptors[0]
            )
            closeExecutionDescriptor(
                descriptors[1]
            )
        }

        let runtime =
            try EventedIORuntime()
        let io =
            IO(
                runtime
            )

        let readDescriptor =
            descriptors[0]

        let waiter =
            Task {
                try await io.wait(
                    descriptor:
                        readDescriptor,
                    for:
                        .readable
                )
            }

        try await io.sleep(
            for:
                .init(
                    nanoseconds:
                        2_000_000
                )
        )

        runtime.shutdown()

        do {
            try await waiter.value

            throw TestFailure(
                message:
                    "pending wait unexpectedly survived runtime shutdown"
            )
        } catch let error
            as IOExecutionError
        {
            guard error
                    == .runtime_stopped
            else {
                throw TestFailure(
                    message:
                        "shutdown returned \(error), expected runtime_stopped"
                )
            }
        }
    }

    static func testIOEventedCancellationReadinessRace()
        async throws
    {
        let runtime =
            try EventedIORuntime()
        defer {
            runtime.shutdown()
        }

        let io =
            IO(
                runtime
            )

        for index in 0..<64 {
            var descriptors:
                [Int32] = [0, 0]
            try makeExecutionPipe(
                &descriptors
            )

            let readDescriptor =
                descriptors[0]

            let waiter =
                Task {
                    try await io.wait(
                        descriptor:
                            readDescriptor,
                        for:
                            .readable,
                        deadline:
                            io.deadline(
                                after:
                                    .init(
                                        seconds: 1
                                    )
                            )
                    )
                }

            await Task.yield()
            await Task.yield()

            if index.isMultiple(
                of: 2
            ) {
                waiter.cancel()
                try writeExecutionByte(
                    descriptor:
                        descriptors[1],
                    byte:
                        0x5A
                )
            } else {
                try writeExecutionByte(
                    descriptor:
                        descriptors[1],
                    byte:
                        0x5A
                )
                waiter.cancel()
            }

            do {
                try await waiter.value
            } catch is CancellationError {
                // Either readiness or cancellation may win this race.
            }

            closeExecutionDescriptor(
                descriptors[0]
            )
            closeExecutionDescriptor(
                descriptors[1]
            )
        }
    }
}

private func makeExecutionPipe(
    _ descriptors:
        inout [Int32]
) throws {
    let result =
        descriptors
            .withUnsafeMutableBufferPointer {
                buffer in

                #if canImport(Darwin)
                Darwin.pipe(
                    buffer.baseAddress
                )
                #elseif canImport(Glibc)
                Glibc.pipe(
                    buffer.baseAddress
                )
                #endif
            }

    guard result == 0 else {
        throw TestFailure(
            message:
                "execution pipe failed with errno \(errno)"
        )
    }
}

private func writeExecutionByte(
    descriptor: Int32,
    byte: UInt8
) throws {
    var byte =
        byte

    let result =
        withUnsafePointer(
            to: &byte
        ) {
            pointer in

            #if canImport(Darwin)
            Darwin.write(
                descriptor,
                pointer,
                1
            )
            #elseif canImport(Glibc)
            Glibc.write(
                descriptor,
                pointer,
                1
            )
            #endif
        }

    guard result == 1 else {
        throw TestFailure(
            message:
                "execution fixture write failed with errno \(errno)"
        )
    }
}

private func closeExecutionDescriptor(
    _ descriptor: Int32
) {
    #if canImport(Darwin)
    _ = Darwin.close(
        descriptor
    )
    #elseif canImport(Glibc)
    _ = Glibc.close(
        descriptor
    )
    #endif
}
