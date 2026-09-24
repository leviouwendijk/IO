import Foundation
import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct AsyncTestCase {
    let name: String
    let body:
        () async throws -> Void
}

extension TestIO {
    package static func runExecution(
        arguments: [String]
    ) async throws {
        let options =
            Set(
                arguments
            )
        let verbose =
            options.contains(
                "--verbose"
            )
            || options.contains(
                "-v"
            )

        let tests: [AsyncTestCase] = [
            .init(
                name:
                    "io-blocking-work-reference",
                body:
                    testIOBlockingWorkReference
            ),
            .init(
                name:
                    "io-blocking-readiness",
                body:
                    testIOBlockingReadiness
            ),
            .init(
                name:
                    "io-blocking-deadline",
                body:
                    testIOBlockingDeadline
            ),
            .init(
                name:
                    "io-blocking-sleep",
                body:
                    testIOBlockingSleep
            ),
            .init(
                name:
                    "io-cancellation-boundary",
                body:
                    testIOCancellationBoundary
            ),
            .init(
                name:
                    "io-evented-readiness",
                body:
                    testIOEventedReadiness
            ),
            .init(
                name:
                    "io-evented-deadline",
                body:
                    testIOEventedDeadline
            ),
            .init(
                name:
                    "io-evented-cancellation-wakeup",
                body:
                    testIOEventedCancellationWakeup
            ),
            .init(
                name:
                    "io-evented-many-waiters",
                body:
                    testIOEventedManyWaiters
            ),
            .init(
                name:
                    "io-evented-worker-concurrency",
                body:
                    testIOEventedWorkerConcurrency
            ),
            .init(
                name:
                    "io-evented-reactor-worker-isolation",
                body:
                    testIOEventedReactorResponsiveDuringWorkerBlock
            ),
            .init(
                name:
                    "io-evented-shutdown-pending-wait",
                body:
                    testIOEventedShutdownPendingWait
            ),
            .init(
                name:
                    "io-evented-cancel-readiness-race",
                body:
                    testIOEventedCancellationReadinessRace
            ),
            .init(
                name:
                    "io-socket-source-runtime-matrix",
                body:
                    testIOSocketSourceRuntimeMatrix
            ),
            .init(
                name:
                    "io-socket-destination-write-runtime-matrix",
                body:
                    testIOSocketDestinationWriteRuntimeMatrix
            ),
            .init(
                name:
                    "io-socket-destination-flush-runtime-matrix",
                body:
                    testIOSocketDestinationFlushRuntimeMatrix
            ),
            .init(
                name:
                    "io-socket-source-deadline",
                body:
                    testIOSocketSourceDeadline
            ),
            .init(
                name:
                    "io-file-transfer-runtime-matrix",
                body:
                    testIOFileTransferRuntimeMatrix
            ),
            .init(
                name:
                    "io-file-worker-reactor-isolation",
                body:
                    testIOFileWorkerReactorIsolation
            ),
            .init(
                name:
                    "io-runtime-lifetime",
                body:
                    testIORuntimeLifetime
            ),
        ]

        var failures:
            [String] = []

        if verbose {
            print(
                "tio_exec"
            )
            print(
                "tests: \(tests.count)"
            )
            print(
                ""
            )
        }

        for test in tests {
            if verbose {
                print(
                    "[RUN ] \(test.name)"
                )
            }

            do {
                try await test.body()

                if verbose {
                    print(
                        "[PASS] \(test.name)"
                    )
                }
            } catch {
                let failure =
                    "\(test.name): \(error)"

                failures.append(
                    failure
                )
                print(
                    "[FAIL] \(failure)"
                )
            }
        }

        print(
            ""
        )
        print(
            "tio_exec: \(tests.count - failures.count)/\(tests.count) passed"
        )

        guard failures.isEmpty else {
            throw TestFailure(
                message:
                    failures.joined(
                        separator: "\n"
                    )
            )
        }
    }

    private static func testIOBlockingWorkReference()
        async throws
    {
        let io =
            IO.blocking

        let value =
            try await io.runBlocking {
                82
            }

        guard value == 82 else {
            throw TestFailure(
                message:
                    "blocking work returned \(value), expected 82"
            )
        }
    }

    private static func testIOBlockingReadiness()
        async throws
    {
        var descriptors:
            [Int32] = [0, 0]

        guard pipe(
            &descriptors
        ) == 0 else {
            throw TestFailure(
                message:
                    "pipe failed with errno \(errno)"
            )
        }

        defer {
            _ = close(
                descriptors[0]
            )
            _ = close(
                descriptors[1]
            )
        }

        var byte:
            UInt8 = 0xA5

        let written =
            withUnsafePointer(
                to: &byte
            ) {
                pointer in

                write(
                    descriptors[1],
                    pointer,
                    1
                )
            }

        guard written == 1 else {
            throw TestFailure(
                message:
                    "fixture write failed with errno \(errno)"
            )
        }

        try await IO.blocking.wait(
            descriptor:
                descriptors[0],
            for:
                .readable,
            deadline:
                IO.blocking.deadline(
                    after:
                        .init(
                            seconds: 1
                        )
                )
        )
    }

    private static func testIOBlockingDeadline()
        async throws
    {
        var descriptors:
            [Int32] = [0, 0]

        guard pipe(
            &descriptors
        ) == 0 else {
            throw TestFailure(
                message:
                    "pipe failed with errno \(errno)"
            )
        }

        defer {
            _ = close(
                descriptors[0]
            )
            _ = close(
                descriptors[1]
            )
        }

        let io =
            IO.blocking
        let deadline =
            io.deadline(
                after:
                    .init(
                        nanoseconds:
                            5_000_000
                    )
            )

        do {
            try await io.wait(
                descriptor:
                    descriptors[0],
                for:
                    .readable,
                deadline:
                    deadline
            )

            throw TestFailure(
                message:
                    "blocking wait unexpectedly completed without readiness"
            )
        } catch let error
            as IOExecutionError
        {
            guard error
                    == .timed_out
            else {
                throw TestFailure(
                    message:
                        "blocking wait returned \(error), expected timed_out"
                )
            }
        }
    }

    private static func testIOBlockingSleep()
        async throws
    {
        let io =
            IO.blocking
        let before =
            io.deadline(
                after:
                    .init(
                        nanoseconds: 0
                    )
            )

        try await io.sleep(
            for:
                .init(
                    nanoseconds:
                        1_000_000
                )
        )

        let after =
            io.deadline(
                after:
                    .init(
                        nanoseconds: 0
                    )
            )

        guard after > before else {
            throw TestFailure(
                message:
                    "blocking sleep did not advance the runtime monotonic clock"
            )
        }
    }

    private static func testIOCancellationBoundary()
        async throws
    {
        let io =
            IO.blocking

        let task =
            Task {
                while !Task.isCancelled {
                    await Task.yield()
                }

                try await io.sleep(
                    for:
                        .init(
                            nanoseconds:
                                1_000_000
                        )
                )
            }

        task.cancel()

        do {
            try await task.value

            throw TestFailure(
                message:
                    "cancelled IO operation unexpectedly succeeded"
            )
        } catch is CancellationError {
            // E1 guarantees cancellation at the async capability boundary.
        }
    }

    private static func testIORuntimeLifetime()
        async throws
    {
        let counter =
            RuntimeLifetimeCounter()

        do {
            let io =
                IO(
                    RuntimeLifetimeProbe(
                        counter:
                            counter
                    )
                )

            _ = io.deadline(
                after:
                    .init(
                        nanoseconds: 1
                    )
            )
        }

        guard counter.count == 1 else {
            throw TestFailure(
                message:
                    "IO runtime destruction count \(counter.count), expected 1"
            )
        }
    }
}

private final class RuntimeLifetimeCounter:
    @unchecked Sendable
{
    var count:
        Int = 0
}

private final class RuntimeLifetimeProbe:
    IORuntime,
    @unchecked Sendable
{
    private let counter:
        RuntimeLifetimeCounter

    init(
        counter:
            RuntimeLifetimeCounter
    ) {
        self.counter =
            counter
    }

    deinit {
        counter.count += 1
    }

    func monotonicNanoseconds()
        -> UInt64
    {
        0
    }

    func wait(
        _ request: IOWaitRequest,
        completion:
            @escaping @Sendable
            (IOExecutionError?) -> Void
    ) {
        _ = request
        completion(
            nil
        )
    }

    func sleep(
        for duration: IODuration,
        completion:
            @escaping @Sendable
            (IOExecutionError?) -> Void
    ) {
        _ = duration
        completion(
            nil
        )
    }

    func submitBlocking(
        _ operation:
            @escaping @Sendable
            () -> Void
    ) {
        operation()
    }
}
