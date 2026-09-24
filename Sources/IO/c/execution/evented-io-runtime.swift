import Atomos
import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One-thread readiness reactor with an optional blocking-worker lane.
///
/// The reactor owns descriptor waits, deadlines, sleeps, wakeups, and
/// cancellation. With `workerCount == 0`, `submitBlocking` is deliberately
/// executed on the reactor thread and can stall reactor progress. Supplying
/// workers produces the hybrid evented + blocking-worker configuration without
/// changing the `IO` interface.
public final class EventedIORuntime:
    IORuntime,
    @unchecked Sendable
{
    private let reactor:
        EventedIOReactor
    private let workers:
        [DispatchQueue]
    private let workerLock =
        NSLock()
    private var nextWorker =
        0

    public init(
        workerCount: Int = 0
    ) throws {
        precondition(
            workerCount >= 0
        )

        self.reactor =
            try EventedIOReactor()

        self.workers =
            (0..<workerCount).map {
                index in

                DispatchQueue(
                    label:
                        "io.runtime.worker.\(index)"
                )
            }

        reactor.start()
    }

    deinit {
        reactor.shutdown()
    }

    public func shutdown() {
        reactor.shutdown()
    }

    public func monotonicNanoseconds()
        -> UInt64
    {
        reactor.monotonicNanoseconds()
    }

    public func wait(
        _ request: IOWaitRequest,
        completion:
            @escaping @Sendable
            (IOExecutionError?) -> Void
    ) {
        _ = beginWait(
            request,
            completion:
                completion
        )
    }

    @discardableResult
    public func beginWait(
        _ request: IOWaitRequest,
        completion:
            @escaping @Sendable
            (IOExecutionError?) -> Void
    ) -> IOOperation? {
        reactor.registerWait(
            request,
            completion:
                completion
        )
    }

    public func sleep(
        for duration: IODuration,
        completion:
            @escaping @Sendable
            (IOExecutionError?) -> Void
    ) {
        _ = beginSleep(
            for: duration,
            completion:
                completion
        )
    }

    @discardableResult
    public func beginSleep(
        for duration: IODuration,
        completion:
            @escaping @Sendable
            (IOExecutionError?) -> Void
    ) -> IOOperation? {
        reactor.registerSleep(
            duration,
            completion:
                completion
        )
    }

    public func cancel(
        _ operation: IOOperation
    ) {
        reactor.cancel(
            operation
        )
    }

    public func submitBlocking(
        _ operation:
            @escaping @Sendable
            () -> Void
    ) {
        guard !workers.isEmpty else {
            reactor.submitWork(
                operation
            )
            return
        }

        workerLock.lock()
        let queue =
            workers[
                nextWorker
                    % workers.count
            ]
        nextWorker =
            (
                nextWorker + 1
            )
            % workers.count
        workerLock.unlock()

        queue.async(
            execute:
                operation
        )
    }
}

private final class EventedIOReactor:
    @unchecked Sendable
{
    private struct WaitRegistration {
        let request:
            IOWaitRequest
        let completion:
            @Sendable
            (IOExecutionError?) -> Void
    }

    private struct SleepRegistration {
        let target:
            UInt64
        let completion:
            @Sendable
            (IOExecutionError?) -> Void
    }

    private struct WaitSnapshot {
        let operation:
            IOOperation
        let descriptor:
            Int32
        let events:
            Int16
    }

    private struct Snapshot {
        let waits:
            [WaitSnapshot]
        let timeout:
            Int32
        let isStopped:
            Bool
    }

    private typealias Completion =
        (
            @Sendable
            (IOExecutionError?) -> Void,
            IOExecutionError?
        )

    private let lock =
        NSLock()
    private let wakeRead:
        Int32
    private let wakeWrite:
        Int32

    private var nextOperation:
        UInt64 = 1
    private var waits:
        [IOOperation: WaitRegistration] = [:]
    private var sleeps:
        [IOOperation: SleepRegistration] = [:]
    private var work:
        [@Sendable () -> Void] = []
    private var isStopped =
        false
    private var thread:
        Thread?

    init() throws {
        var descriptors:
            [Int32] = [-1, -1]

        let result =
            descriptors
                .withUnsafeMutableBufferPointer {
                    buffer in

                    systemPipe(
                        buffer.baseAddress
                    )
                }

        guard result == 0 else {
            throw IOExecutionError
                .system_call_failed(
                    code: errno
                )
        }

        do {
            try setNonblocking(
                descriptors[0]
            )
            try setNonblocking(
                descriptors[1]
            )
            try setCloseOnExec(
                descriptors[0]
            )
            try setCloseOnExec(
                descriptors[1]
            )
        } catch {
            systemClose(
                descriptors[0]
            )
            systemClose(
                descriptors[1]
            )
            throw error
        }

        self.wakeRead =
            descriptors[0]
        self.wakeWrite =
            descriptors[1]
    }

    /// The wake pipe is closed only here, never by the reactor thread. Every caller
    /// that can still reach `wake()` holds a reference to this reactor, so the
    /// descriptors cannot be closed, and their numbers reused, while a late
    /// `wake()` is still possible. Once the reactor stops, surplus wake bytes just
    /// fill the nonblocking pipe (`EAGAIN` is ignored).
    deinit {
        systemClose(
            wakeRead
        )
        systemClose(
            wakeWrite
        )
    }

    func start() {
        let thread =
            Thread {
                [weak self] in

                self?.run()
            }

        thread.name =
            "io.runtime.reactor"

        lock.lock()
        self.thread =
            thread
        lock.unlock()

        thread.start()
    }

    func monotonicNanoseconds()
        -> UInt64
    {
        IOMonotonicDomain.nanoseconds()
    }

    func registerWait(
        _ request: IOWaitRequest,
        completion:
            @escaping @Sendable
            (IOExecutionError?) -> Void
    ) -> IOOperation? {
        guard request.descriptor >= 0 else {
            completion(
                .invalid_descriptor
            )
            return nil
        }

        guard !request.interest.isEmpty else {
            completion(
                .invalid_interest
            )
            return nil
        }

        lock.lock()

        guard !isStopped else {
            lock.unlock()
            completion(
                .runtime_stopped
            )
            return nil
        }

        let operation =
            makeOperationLocked()

        waits[operation] =
            .init(
                request: request,
                completion:
                    completion
            )

        lock.unlock()
        wake()
        return operation
    }

    func registerSleep(
        _ duration: IODuration,
        completion:
            @escaping @Sendable
            (IOExecutionError?) -> Void
    ) -> IOOperation? {
        guard duration.nanoseconds > 0 else {
            completion(
                nil
            )
            return nil
        }

        let now =
            monotonicNanoseconds()
        let delta =
            UInt64(
                duration.nanoseconds
            )
        let (
            target,
            overflow
        ) =
            now.addingReportingOverflow(
                delta
            )

        lock.lock()

        guard !isStopped else {
            lock.unlock()
            completion(
                .runtime_stopped
            )
            return nil
        }

        let operation =
            makeOperationLocked()

        sleeps[operation] =
            .init(
                target:
                    overflow
                    ? UInt64.max
                    : target,
                completion:
                    completion
            )

        lock.unlock()
        wake()
        return operation
    }

    func cancel(
        _ operation: IOOperation
    ) {
        let completion:
            (@Sendable
            (IOExecutionError?) -> Void)?

        lock.lock()

        if let registration =
            waits.removeValue(
                forKey: operation
            )
        {
            completion =
                registration.completion
        } else if let registration =
            sleeps.removeValue(
                forKey: operation
            )
        {
            completion =
                registration.completion
        } else {
            completion =
                nil
        }

        lock.unlock()

        guard let completion else {
            return
        }

        wake()
        completion(
            .cancelled
        )
    }

    func submitWork(
        _ operation:
            @escaping @Sendable
            () -> Void
    ) {
        lock.lock()

        if isStopped {
            lock.unlock()
            operation()
            return
        }

        work.append(
            operation
        )
        lock.unlock()
        wake()
    }

    func shutdown() {
        var completions:
            [Completion] = []

        lock.lock()

        guard !isStopped else {
            lock.unlock()
            return
        }

        isStopped =
            true

        completions.reserveCapacity(
            waits.count
                + sleeps.count
        )

        for registration
            in waits.values
        {
            completions.append(
                (
                    registration.completion,
                    .runtime_stopped
                )
            )
        }

        for registration
            in sleeps.values
        {
            completions.append(
                (
                    registration.completion,
                    .runtime_stopped
                )
            )
        }

        waits.removeAll(
            keepingCapacity: false
        )
        sleeps.removeAll(
            keepingCapacity: false
        )

        lock.unlock()
        wake()
        run(
            completions
        )
    }

    private func run() {
        while true {
            let (
                pendingWork,
                stopped
            ) =
                takeWork()

            for operation
                in pendingWork
            {
                operation()
            }

            if stopped {
                break
            }

            let snapshot =
                makeSnapshot()

            if snapshot.isStopped {
                continue
            }

            var descriptors:
                [pollfd] = [
                    .init(
                        fd: wakeRead,
                        events:
                            Int16(
                                POLLIN
                            ),
                        revents: 0
                    )
                ]

            descriptors.reserveCapacity(
                snapshot.waits.count
                    + 1
            )

            for wait
                in snapshot.waits
            {
                descriptors.append(
                    .init(
                        fd:
                            wait.descriptor,
                        events:
                            wait.events,
                        revents: 0
                    )
                )
            }

            let result =
                systemPoll(
                    &descriptors,
                    timeout:
                        snapshot.timeout
                )

            if result < 0 {
                let code =
                    errno

                if code == EINTR {
                    continue
                }

                stopAfterPollFailure(
                    code
                )
                continue
            }

            if result > 0
                && descriptors[0].revents
                    != 0
            {
                drainWake()
            }

            let completions =
                collectCompletions(
                    snapshot:
                        snapshot,
                    descriptors:
                        descriptors
                )

            run(
                completions
            )
        }
    }

    private func takeWork()
        -> (
            [@Sendable () -> Void],
            Bool
        )
    {
        lock.lock()
        let pending =
            work
        work.removeAll(
            keepingCapacity: true
        )
        let stopped =
            isStopped
        lock.unlock()

        return (
            pending,
            stopped
        )
    }

    private func makeSnapshot()
        -> Snapshot
    {
        let now =
            monotonicNanoseconds()

        lock.lock()

        let waitSnapshots =
            waits.map {
                operation,
                registration in

                WaitSnapshot(
                    operation:
                        operation,
                    descriptor:
                        registration.request
                            .descriptor,
                    events:
                        pollEvents(
                            registration.request
                                .interest
                        )
                )
            }

        var nearest:
            UInt64?

        for registration
            in waits.values
        {
            if let deadline =
                registration.request
                    .deadline?.nanosecondsSinceRuntimeEpoch
            {
                nearest =
                    minOptional(
                        nearest,
                        deadline
                    )
            }
        }

        for registration
            in sleeps.values
        {
            nearest =
                minOptional(
                    nearest,
                    registration.target
                )
        }

        let stopped =
            isStopped

        lock.unlock()

        return .init(
            waits:
                waitSnapshots,
            timeout:
                pollTimeout(
                    now: now,
                    target:
                        nearest
                ),
            isStopped:
                stopped
        )
    }

    private func collectCompletions(
        snapshot: Snapshot,
        descriptors: [pollfd]
    ) -> [Completion] {
        let now =
            monotonicNanoseconds()
        var completions:
            [Completion] = []

        lock.lock()

        for (
            index,
            wait
        ) in snapshot.waits
            .enumerated()
        {
            guard waits[
                wait.operation
            ] != nil
            else {
                continue
            }

            let revents =
                descriptors[
                    index + 1
                ]
                .revents

            if revents
                & Int16(
                    POLLNVAL
                )
                != 0
            {
                if let registration =
                    waits.removeValue(
                        forKey:
                            wait.operation
                    )
                {
                    completions.append(
                        (
                            registration.completion,
                            .invalid_descriptor
                        )
                    )
                }
                continue
            }

            let progressMask =
                wait.events
                | Int16(
                    POLLERR
                )
                | Int16(
                    POLLHUP
                )

            if revents
                & progressMask
                != 0
            {
                if let registration =
                    waits.removeValue(
                        forKey:
                            wait.operation
                    )
                {
                    completions.append(
                        (
                            registration.completion,
                            nil
                        )
                    )
                }
            }
        }

        let timedOutWaits =
            waits.compactMap {
                operation,
                registration
                -> IOOperation? in

                guard let deadline =
                    registration.request
                        .deadline?.nanosecondsSinceRuntimeEpoch,
                    deadline <= now
                else {
                    return nil
                }

                return operation
            }

        for operation
            in timedOutWaits
        {
            if let registration =
                waits.removeValue(
                    forKey:
                        operation
                )
            {
                completions.append(
                    (
                        registration.completion,
                        .timed_out
                    )
                )
            }
        }

        let completedSleeps =
            sleeps.compactMap {
                operation,
                registration
                -> IOOperation? in

                registration.target
                    <= now
                ? operation
                : nil
            }

        for operation
            in completedSleeps
        {
            if let registration =
                sleeps.removeValue(
                    forKey:
                        operation
                )
            {
                completions.append(
                    (
                        registration.completion,
                        nil
                    )
                )
            }
        }

        lock.unlock()
        return completions
    }

    private func stopAfterPollFailure(
        _ code: Int32
    ) {
        var completions:
            [Completion] = []

        lock.lock()
        isStopped =
            true

        for registration
            in waits.values
        {
            completions.append(
                (
                    registration.completion,
                    .system_call_failed(
                        code: code
                    )
                )
            )
        }

        for registration
            in sleeps.values
        {
            completions.append(
                (
                    registration.completion,
                    .system_call_failed(
                        code: code
                    )
                )
            )
        }

        waits.removeAll(
            keepingCapacity: false
        )
        sleeps.removeAll(
            keepingCapacity: false
        )
        lock.unlock()

        run(
            completions
        )
    }

    private func makeOperationLocked()
        -> IOOperation
    {
        let operation =
            IOOperation(
                rawValue:
                    nextOperation
            )

        nextOperation &+=
            1

        if nextOperation == 0 {
            nextOperation =
                1
        }

        return operation
    }

    private func wake() {
        var byte:
            UInt8 = 1

        while true {
            let result =
                withUnsafePointer(
                    to: &byte
                ) {
                    pointer in

                    systemWrite(
                        wakeWrite,
                        pointer,
                        1
                    )
                }

            if result == 1 {
                return
            }

            if result < 0
                && errno == EINTR
            {
                continue
            }

            // EAGAIN means a wake byte is already pending, which is sufficient.
            return
        }
    }

    private func drainWake() {
        var bytes =
            [UInt8](
                repeating: 0,
                count: 64
            )

        while true {
            let result =
                bytes
                    .withUnsafeMutableBytes {
                        raw in

                        systemRead(
                            wakeRead,
                            raw.baseAddress,
                            raw.count
                        )
                    }

            if result > 0 {
                continue
            }

            if result < 0
                && errno == EINTR
            {
                continue
            }

            return
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
        now: UInt64,
        target: UInt64?
    ) -> Int32 {
        guard let target else {
            return -1
        }

        guard target > now else {
            return 0
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

    private func minOptional(
        _ lhs: UInt64?,
        _ rhs: UInt64
    ) -> UInt64 {
        guard let lhs else {
            return rhs
        }

        return min(
            lhs,
            rhs
        )
    }

    private func run(
        _ completions:
            [Completion]
    ) {
        for (
            completion,
            error
        ) in completions
        {
            completion(
                error
            )
        }
    }
}

private func setNonblocking(
    _ descriptor: Int32
) throws {
    let flags =
        systemFcntlGetFlags(
            descriptor
        )

    guard flags >= 0 else {
        throw IOExecutionError
            .system_call_failed(
                code: errno
            )
    }

    guard systemFcntlSetFlags(
        descriptor,
        flags
            | O_NONBLOCK
    ) >= 0
    else {
        throw IOExecutionError
            .system_call_failed(
                code: errno
            )
    }
}

/// Marks a descriptor close-on-exec so spawned processes do not inherit it.
///
/// Darwin has no `pipe2`, so the flag is set right after `pipe`; the reactor
/// creates its wake pipe during init, before any descriptor is handed out.
private func setCloseOnExec(
    _ descriptor: Int32
) throws {
    #if canImport(Darwin)
    let result = Darwin.fcntl(
        descriptor,
        F_SETFD,
        FD_CLOEXEC
    )
    #elseif canImport(Glibc)
    let result = Glibc.fcntl(
        descriptor,
        F_SETFD,
        FD_CLOEXEC
    )
    #endif

    guard result >= 0 else {
        throw IOExecutionError
            .system_call_failed(
                code: errno
            )
    }
}

private func systemPipe(
    _ descriptors:
        UnsafeMutablePointer<Int32>?
) -> Int32 {
    #if canImport(Darwin)
    Darwin.pipe(
        descriptors
    )
    #elseif canImport(Glibc)
    Glibc.pipe(
        descriptors
    )
    #endif
}

private func systemFcntlGetFlags(
    _ descriptor: Int32
) -> Int32 {
    #if canImport(Darwin)
    Darwin.fcntl(
        descriptor,
        F_GETFL
    )
    #elseif canImport(Glibc)
    Glibc.fcntl(
        descriptor,
        F_GETFL
    )
    #endif
}

private func systemFcntlSetFlags(
    _ descriptor: Int32,
    _ flags: Int32
) -> Int32 {
    #if canImport(Darwin)
    Darwin.fcntl(
        descriptor,
        F_SETFL,
        flags
    )
    #elseif canImport(Glibc)
    Glibc.fcntl(
        descriptor,
        F_SETFL,
        flags
    )
    #endif
}

private func systemPoll(
    _ descriptors:
        inout [pollfd],
    timeout: Int32
) -> Int32 {
    descriptors
        .withUnsafeMutableBufferPointer {
            buffer in

            #if canImport(Darwin)
            Darwin.poll(
                buffer.baseAddress,
                nfds_t(
                    buffer.count
                ),
                timeout
            )
            #elseif canImport(Glibc)
            Glibc.poll(
                buffer.baseAddress,
                nfds_t(
                    buffer.count
                ),
                timeout
            )
            #endif
        }
}

private func systemRead(
    _ descriptor: Int32,
    _ pointer: UnsafeMutableRawPointer?,
    _ count: Int
) -> Int {
    #if canImport(Darwin)
    Darwin.read(
        descriptor,
        pointer,
        count
    )
    #elseif canImport(Glibc)
    Glibc.read(
        descriptor,
        pointer,
        count
    )
    #endif
}

private func systemWrite(
    _ descriptor: Int32,
    _ pointer: UnsafeRawPointer?,
    _ count: Int
) -> Int {
    #if canImport(Darwin)
    Darwin.write(
        descriptor,
        pointer,
        count
    )
    #elseif canImport(Glibc)
    Glibc.write(
        descriptor,
        pointer,
        count
    )
    #endif
}

private func systemClose(
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
