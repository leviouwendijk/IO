import Atomos

/// IO scheduling duration vocabulary is the Atomos monotonic duration primitive.
public typealias IODuration =
    MonotonicClock.Duration

/// Process-wide monotonic domain for `IODeadline`, on Atomos `MonotonicClock`.
///
/// One anchor instant is shared by every runtime and every `IO` value, so a
/// deadline created through one `IO` denotes the same instant on any other
/// runtime in the process. Runtimes must not keep private epochs.
package enum IOMonotonicDomain {
    private static let clock =
        MonotonicClock()
    private static let anchor =
        clock.now

    package static func nanoseconds()
        -> UInt64
    {
        let elapsed =
            anchor.duration(
                to: clock.now
            )

        guard elapsed.nanoseconds > 0 else {
            return 0
        }

        return UInt64(
            elapsed.nanoseconds
        )
    }
}

/// Absolute deadline in the process-wide `IOMonotonicDomain` domain.
///
/// A deadline created through any `IO` value is valid on every runtime in the
/// process. The raw value is deliberately package-only; construct deadlines
/// through `IO.deadline(after:)`.
public struct IODeadline:
    Sendable,
    Hashable,
    Comparable
{
    package let nanosecondsSinceRuntimeEpoch:
        UInt64

    package init(
        nanosecondsSinceRuntimeEpoch:
            UInt64
    ) {
        self.nanosecondsSinceRuntimeEpoch =
            nanosecondsSinceRuntimeEpoch
    }

    public static func < (
        lhs: Self,
        rhs: Self
    ) -> Bool {
        lhs.nanosecondsSinceRuntimeEpoch
            < rhs.nanosecondsSinceRuntimeEpoch
    }
}

/// Opaque identity for one cancellable runtime operation.
///
/// Blocking runtimes may return `nil` from `beginWait` / `beginSleep` when the
/// operation completes synchronously and cannot be interrupted after entry.
public struct IOOperation:
    RawRepresentable,
    Hashable,
    Sendable
{
    public let rawValue:
        UInt64

    public init(
        rawValue: UInt64
    ) {
        self.rawValue =
            rawValue
    }
}

public struct IOWaitRequest:
    Sendable,
    Hashable
{
    public let descriptor:
        Int32
    public let interest:
        ReadinessInterest
    public let deadline:
        IODeadline?

    public init(
        descriptor: Int32,
        interest: ReadinessInterest,
        deadline: IODeadline? = nil
    ) {
        self.descriptor =
            descriptor
        self.interest =
            interest
        self.deadline =
            deadline
    }
}

public enum IOExecutionError:
    Error,
    Sendable,
    Equatable
{
    case timed_out
    case invalid_descriptor
    /// A wait request named no readiness interest, so it could never complete.
    case invalid_interest
    case cancelled
    case runtime_stopped
    case system_call_failed(
        code: Int32
    )
}

/// Runtime-owned execution policy behind a lightweight `IO` capability.
///
/// The callback form is intentional. A blocking runtime may complete callbacks
/// synchronously; a worker runtime may complete them from a worker; an evented
/// runtime may retain them until readiness/timer progress. `IO` supplies the
/// Swift async continuation facade above this contract.
public protocol IORuntime:
    AnyObject,
    Sendable
{
    /// Monotonic nanoseconds in the process-wide `IOMonotonicDomain` domain.
    ///
    /// Deadlines are compared against this value, so runtimes must report
    /// `IOMonotonicDomain.nanoseconds()` rather than a private epoch.
    func monotonicNanoseconds()
        -> UInt64

    func wait(
        _ request: IOWaitRequest,
        completion:
            @escaping @Sendable
            (IOExecutionError?) -> Void
    )

    func sleep(
        for duration: IODuration,
        completion:
            @escaping @Sendable
            (IOExecutionError?) -> Void
    )

    /// Cancellable form used by the `IO` async facade.
    ///
    /// Existing synchronous/blocking runtimes inherit the default implementation
    /// and return `nil`. Evented runtimes return an operation identity that can
    /// be cancelled while suspended.
    @discardableResult
    func beginWait(
        _ request: IOWaitRequest,
        completion:
            @escaping @Sendable
            (IOExecutionError?) -> Void
    ) -> IOOperation?

    @discardableResult
    func beginSleep(
        for duration: IODuration,
        completion:
            @escaping @Sendable
            (IOExecutionError?) -> Void
    ) -> IOOperation?

    func cancel(
        _ operation: IOOperation
    )

    /// Schedules work which is permitted to block an OS thread.
    func submitBlocking(
        _ operation:
            @escaping @Sendable
            () -> Void
    )
}

public extension IORuntime {
    @discardableResult
    func beginWait(
        _ request: IOWaitRequest,
        completion:
            @escaping @Sendable
            (IOExecutionError?) -> Void
    ) -> IOOperation? {
        wait(
            request,
            completion:
                completion
        )
        return nil
    }

    @discardableResult
    func beginSleep(
        for duration: IODuration,
        completion:
            @escaping @Sendable
            (IOExecutionError?) -> Void
    ) -> IOOperation? {
        sleep(
            for: duration,
            completion:
                completion
        )
        return nil
    }

    func cancel(
        _ operation: IOOperation
    ) {
        _ = operation
    }
}
