import Atomos

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Single-thread blocking reference runtime.
///
/// This is deliberately the simplest implementation of `IORuntime`: blocking
/// work executes inline and readiness waits use blocking `poll`. It establishes
/// semantics for later worker/reactor implementations rather than attempting to
/// provide concurrency itself.
public final class BlockingIORuntime:
    IORuntime,
    @unchecked Sendable
{
    private let clock:
        MonotonicClock
    private let epoch:
        MonotonicClock.Instant

    public init() {
        let clock =
            MonotonicClock()

        self.clock =
            clock
        self.epoch =
            clock.now
    }

    public func monotonicNanoseconds()
        -> UInt64
    {
        let elapsed =
            epoch.duration(
                to: clock.now
            )

        guard elapsed.nanoseconds > 0 else {
            return 0
        }

        return UInt64(
            elapsed.nanoseconds
        )
    }

    public func submitBlocking(
        _ operation:
            @escaping @Sendable
            () -> Void
    ) {
        operation()
    }

    public func sleep(
        for duration: IODuration,
        completion:
            @escaping @Sendable
            (IOExecutionError?) -> Void
    ) {
        clock.sleep(
            for: duration
        )
        completion(
            nil
        )
    }

    public func wait(
        _ request: IOWaitRequest,
        completion:
            @escaping @Sendable
            (IOExecutionError?) -> Void
    ) {
        do {
            try blockingWait(
                request
            )
            completion(
                nil
            )
        } catch let error
            as IOExecutionError
        {
            completion(
                error
            )
        } catch {
            completion(
                .system_call_failed(
                    code: EIO
                )
            )
        }
    }

    private func blockingWait(
        _ request:
            IOWaitRequest
    ) throws {
        var descriptor =
            pollfd(
                fd:
                    request.descriptor,
                events:
                    pollEvents(
                        request.interest
                    ),
                revents: 0
            )

        while true {
            let timeout =
                try pollTimeout(
                    deadline:
                        request.deadline
                )

            let result =
                poll(
                    &descriptor,
                    1,
                    timeout
                )

            if result > 0 {
                if descriptor.revents
                    & Int16(
                        POLLNVAL
                    )
                    != 0
                {
                    throw IOExecutionError
                        .invalid_descriptor
                }

                // POLLERR/POLLHUP are progress-worthy: the following endpoint
                // operation must observe the actual EOF/error condition.
                return
            }

            if result == 0 {
                throw IOExecutionError
                    .timed_out
            }

            let code =
                errno

            if code == EINTR {
                continue
            }

            throw IOExecutionError
                .system_call_failed(
                    code: code
                )
        }
    }

    private func pollEvents(
        _ interest:
            ReadinessInterest
    ) -> Int16 {
        var events:
            Int16 = 0

        if interest.contains(
            .readable
        ) {
            events |=
                Int16(
                    POLLIN
                )
        }

        if interest.contains(
            .writable
        ) {
            events |=
                Int16(
                    POLLOUT
                )
        }

        return events
    }

    private func pollTimeout(
        deadline:
            IODeadline?
    ) throws -> Int32 {
        guard let deadline else {
            return -1
        }

        let now =
            monotonicNanoseconds()
        let target =
            deadline
                .nanosecondsSinceRuntimeEpoch

        guard target > now else {
            throw IOExecutionError
                .timed_out
        }

        let remaining =
            target - now
        let milliseconds =
            remaining / 1_000_000
            + (
                remaining % 1_000_000
                    == 0
                ? 0
                : 1
            )

        return Int32(
            min(
                milliseconds,
                UInt64(
                    Int32.max
                )
            )
        )
    }
}
