/// Explicit I/O capability passed through code that may interact with the
/// outside world or suspend for I/O progress.
///
/// `IO` is intentionally a lightweight handle. The runtime owns execution
/// machinery; resources own native handles; Source/Destination own byte-flow
/// and staging state; allocators remain separate.
public struct IO: Sendable {
    private let runtime: any IORuntime

    public init<Runtime: IORuntime>(
        _ runtime: Runtime
    ) {
        self.runtime = runtime
    }

    /// Reference implementation: waits and blocking work execute directly on
    /// the caller's current thread.
    public static var blocking: Self {
        .init(BlockingIORuntime())
    }

    /// Evented runtime with one reactor thread and an optional blocking-worker
    /// lane. `workerCount == 0` keeps blocking work on the reactor itself;
    /// positive counts offload blocking work to worker lanes.
    public static func evented(
        workerCount: Int = 0
    ) throws -> Self {
        .init(
            try EventedIORuntime(
                workerCount:
                    workerCount
            )
        )
    }

    /// Deadline `duration` from now in the process-wide monotonic domain.
    ///
    /// The result is independent of this `IO`'s runtime and may be passed to any
    /// other `IO` in the process.
    public func deadline(
        after duration: IODuration
    ) -> IODeadline {
        let now = IOMonotonicDomain.nanoseconds()

        guard duration.nanoseconds > 0 else {
            return .init(nanosecondsSinceRuntimeEpoch:
                now
            )
        }

        let delta = UInt64(
            duration.nanoseconds
        )

        let (value, overflow) = now.addingReportingOverflow(
            delta
        )

        return .init(nanosecondsSinceRuntimeEpoch:
            overflow ? UInt64.max : value
        )
    }

    /// Waits until the supplied descriptor can plausibly make progress.
    ///
    /// Blocking runtimes may block the current thread. Evented runtimes retain
    /// the continuation behind an operation token and resume it on readiness,
    /// timeout, cancellation, or runtime shutdown.
    public func wait(
        descriptor: Int32,
        for interest: ReadinessInterest,
        deadline: IODeadline? = nil
    ) async throws {
        try Task.checkCancellation()

        // Malformed requests can never complete: poll ignores negative
        // descriptors and empty interest never becomes ready.
        guard descriptor >= 0 else {
            throw IOExecutionError.invalid_descriptor
        }

        guard !interest.isEmpty else {
            throw IOExecutionError.invalid_interest
        }

        let cancellation = IOCancellationSlot()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in

                let operation = runtime.beginWait(
                    .init(
                        descriptor:
                            descriptor,
                        interest:
                            interest,
                        deadline:
                            deadline
                    )
                ) {
                    error in

                    resume(
                        continuation,
                        with: error
                    )
                }

                cancellation.install(
                    operation,
                    runtime: runtime
                )
            }
        } onCancel: {
            cancellation.cancel(
                runtime: runtime
            )
        }

        try Task.checkCancellation()
    }

    /// Suspends through the selected runtime's timer/sleep mechanism.
    public func sleep(
        for duration: IODuration
    ) async throws {
        try Task.checkCancellation()

        let cancellation = IOCancellationSlot()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in

                let operation = runtime.beginSleep(
                    for: duration
                ) {
                    error in

                    resume(
                        continuation,
                        with: error
                    )
                }

                cancellation.install(
                    operation,
                    runtime: runtime
                )
            }
        } onCancel: {
            cancellation.cancel(
                runtime: runtime
            )
        }

        try Task.checkCancellation()
    }

    /// Executes an operation through the runtime's blocking-work lane.
    ///
    /// The blocking reference runtime executes inline. An evented runtime with
    /// no workers executes this lane on its reactor thread; a hybrid evented
    /// runtime dispatches it to configured workers.
    ///
    /// Cancellation is checked only before submission. A submitted operation
    /// cannot be interrupted, so once it has run its completion wins: the produced
    /// value (which may own resources) is returned even if the calling task was
    /// cancelled in the meantime.
    public func runBlocking<
        Result: Sendable
    >(
        _ operation: @escaping @Sendable () throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()

        let value: Result =
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Result, Error>) in

                runtime.submitBlocking {
                    do {
                        continuation.resume(
                            returning: try operation()
                        )
                    } catch {
                        continuation.resume(
                            throwing: error
                        )
                    }
                }
            }

        return value
    }

    private func resume(
        _ continuation: CheckedContinuation<Void, Error>,
        with error: IOExecutionError?
    ) {
        guard let error else {
            continuation.resume()
            return
        }

        if error == .cancelled {
            continuation.resume(
                throwing: CancellationError()
            )
            return
        }

        continuation.resume(
            throwing: error
        )
    }
}
