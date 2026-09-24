import Atomos

/// IO scheduling duration vocabulary is the Atomos monotonic duration primitive.
public typealias IODuration =
    MonotonicClock.Duration

/// Absolute deadline within one IORuntime monotonic domain.
///
/// The raw runtime-epoch value is deliberately package-only. Construct deadlines
/// through `IO.deadline(after:)` so consumers do not depend on a runtime epoch.
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
    /// Monotonic nanoseconds in this runtime's arbitrary epoch.
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
