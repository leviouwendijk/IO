#if canImport(Darwin)
import Darwin
import Foundation
import IO

/// Execution-layer probes: audit findings #3a, #4, #5, #6.
enum HZExecutionProbes {
    static var probes: [HazardProbe] {
        [
            .init(
                "wait-negative-fd-blocking",
                finding: "#4",
                timeoutSeconds: 3,
                onTimeout: .present("blocking wait on descriptor -1 without a deadline never completed (hang)"),
                body: { try await waitNegativeDescriptor(evented: false, withDeadline: false) }
            ),
            .init(
                "wait-negative-fd-blocking-deadline",
                finding: "#4",
                timeoutSeconds: 3,
                body: { try await waitNegativeDescriptor(evented: false, withDeadline: true) }
            ),
            .init(
                "wait-negative-fd-evented",
                finding: "#4",
                timeoutSeconds: 3,
                onTimeout: .present("evented wait on descriptor -1 without a deadline never completed (hang)"),
                body: { try await waitNegativeDescriptor(evented: true, withDeadline: false) }
            ),
            .init(
                "wait-empty-interest-blocking",
                finding: "#4",
                timeoutSeconds: 3,
                onTimeout: .present("blocking wait with empty interest never completed (hang)"),
                body: { try await waitEmptyInterest(evented: false) }
            ),
            .init(
                "wait-empty-interest-evented",
                finding: "#4",
                timeoutSeconds: 3,
                onSignal: { signal in
                    .present("empty interest trapped the process (\(HZ.signalName(signal))) instead of returning an error")
                },
                body: { try await waitEmptyInterest(evented: true) }
            ),
            .init(
                "cross-runtime-deadline",
                finding: "#5",
                body: { try await crossRuntimeDeadline() }
            ),
            .init(
                "computed-blocking-runtime-deadline",
                finding: "#5",
                body: { try await computedBlockingRuntimeDeadline() }
            ),
            .init(
                "run-blocking-cancellation-completion",
                finding: "#6",
                body: { try await runBlockingCancellationCompletion() }
            ),
            .init(
                "reactor-inflight-wake-shutdown",
                finding: "#3a",
                timeoutSeconds: 5,
                onTimeout: .present("forced in-flight wake/shutdown interleaving did not complete"),
                body: { try reactorInflightWakeShutdown() }
            ),
            .init(
                "reactor-wake-after-shutdown",
                finding: "#3a",
                body: { try reactorWakeAfterShutdown() }
            ),
        ]
    }

    static func waitNegativeDescriptor(
        evented: Bool,
        withDeadline: Bool
    ) async throws -> HazardOutcome {
        let io = try (evented ? IO.evented() : IO.blocking)
        let deadline = withDeadline
            ? io.deadline(after: .init(nanoseconds: 100_000_000))
            : nil
        let label = "\(evented ? "evented" : "blocking") wait(-1)\(withDeadline ? " with 100 ms deadline" : "")"

        return try await expectPromptRejection(
            io: io,
            descriptor: -1,
            interest: .readable,
            deadline: deadline,
            expected: .invalid_descriptor,
            label: label
        )
    }

    static func waitEmptyInterest(
        evented: Bool
    ) async throws -> HazardOutcome {
        let (readEnd, writeEnd) = try HZ.pipePair()
        defer {
            HZ.close(readEnd)
            HZ.close(writeEnd)
        }

        let io = try (evented ? IO.evented() : IO.blocking)

        return try await expectPromptRejection(
            io: io,
            descriptor: readEnd,
            interest: [],
            deadline: nil,
            expected: nil,
            label: "\(evented ? "evented" : "blocking") wait with empty interest"
        )
    }

    /// `expected == nil` accepts any prompt `IOExecutionError`; there is no
    /// dedicated invalid-interest case yet.
    static func expectPromptRejection(
        io: IO,
        descriptor: Int32,
        interest: ReadinessInterest,
        deadline: IODeadline?,
        expected: IOExecutionError?,
        label: String
    ) async throws -> HazardOutcome {
        HZ.step(label)
        let clock = ContinuousClock()
        let start = clock.now

        do {
            try await io.wait(
                descriptor: descriptor,
                for: interest,
                deadline: deadline
            )
            return .present("\(label): reported readiness instead of rejecting the request")
        } catch let error as IOExecutionError {
            let elapsed = HZ.format(HZ.milliseconds(start.duration(to: clock.now)))

            if let expected, error != expected {
                return .present("\(label): expected \(expected), got \(error) after \(elapsed) ms")
            }

            return .absent("\(label): rejected with \(error) after \(elapsed) ms")
        }
    }

    /// Two blocking runtimes whose epochs differ by ~300 ms exchange 20 ms
    /// deadlines in both directions.
    static func crossRuntimeDeadline() async throws -> HazardOutcome {
        let early = IO(BlockingIORuntime())
        HZ.step("separating runtime epochs by 300 ms")
        usleep(300_000)
        let late = IO(BlockingIORuntime())

        let (readEnd, writeEnd) = try HZ.pipePair()
        defer {
            HZ.close(readEnd)
            HZ.close(writeEnd)
        }

        HZ.step("early deadline consumed by late runtime")
        let forward = try await timedDeadlineWait(
            consumer: late,
            deadline: early.deadline(after: .init(nanoseconds: 20_000_000)),
            descriptor: readEnd
        )

        HZ.step("late deadline consumed by early runtime")
        let backward = try await timedDeadlineWait(
            consumer: early,
            deadline: late.deadline(after: .init(nanoseconds: 20_000_000)),
            descriptor: readEnd
        )

        let detail = "20 ms deadline: made on early runtime, consumed by late → \(HZ.format(forward)) ms; made on late, consumed by early → \(HZ.format(backward)) ms"

        if forward > 150 || backward < 5 {
            return .present(detail)
        }

        return .absent(detail)
    }

    /// `IO.blocking` constructs a fresh runtime (fresh epoch) on every access.
    static func computedBlockingRuntimeDeadline() async throws -> HazardOutcome {
        let (readEnd, writeEnd) = try HZ.pipePair()
        defer {
            HZ.close(readEnd)
            HZ.close(writeEnd)
        }

        let deadline = IO.blocking.deadline(
            after: .init(nanoseconds: 20_000_000)
        )

        HZ.step("letting a 20 ms deadline expire for 200 ms")
        usleep(200_000)

        let elapsed = try await timedDeadlineWait(
            consumer: IO.blocking,
            deadline: deadline,
            descriptor: readEnd
        )
        let detail = "20 ms deadline consumed 200 ms later through a fresh IO.blocking waited \(HZ.format(elapsed)) ms"

        if elapsed > 10 {
            return .present("\(detail); an already-expired deadline was treated as pending")
        }

        return .absent(detail)
    }

    static func timedDeadlineWait(
        consumer: IO,
        deadline: IODeadline,
        descriptor: Int32
    ) async throws -> Double {
        let clock = ContinuousClock()
        let start = clock.now

        do {
            try await consumer.wait(
                descriptor: descriptor,
                for: .readable,
                deadline: deadline
            )
        } catch let error as IOExecutionError where error == .timed_out {}

        return HZ.milliseconds(start.duration(to: clock.now))
    }

    /// Cancels the awaiting task while its blocking operation is already
    /// running, then lets the operation produce a value.
    static func runBlockingCancellationCompletion() async throws -> HazardOutcome {
        let runtime = try EventedIORuntime(workerCount: 1)
        defer { runtime.shutdown() }

        let io = IO(runtime)
        let state = HZState()
        let release = DispatchSemaphore(value: 0)

        let task = Task { () async throws -> Int in
            try await io.runBlocking {
                state.set("started")
                release.wait()
                state.set("produced")
                return 42
            }
        }

        var started = false

        for _ in 0..<2000 {
            if state.isSet("started") {
                started = true
                break
            }

            try await Task.sleep(nanoseconds: 1_000_000)
        }

        guard started else {
            task.cancel()
            release.signal()
            return .inconclusive("blocking operation never started")
        }

        HZ.step("cancelling caller while the blocking operation runs")
        task.cancel()
        release.signal()

        switch await task.result {
        case .success(let value):
            return .absent("already-running operation delivered \(value) despite cancellation")

        case .failure(let error):
            if state.isSet("produced") {
                return .present(
                    "operation completed and produced 42, but the caller received \(type(of: error)) — the produced result was discarded"
                )
            }

            return .inconclusive("caller failed with \(error) before the operation produced")
        }
    }

    /// Deterministic #3a check. The race needed a late `wake()` to write into a wake
    /// pipe already closed, and possibly reused, by shutdown. Asserts that after
    /// `shutdown()` the pipe descriptors still name the same FIFOs, no newly opened
    /// file receives their numbers or any byte from repeated `wake()` calls, and the
    /// descriptors close only once the runtime is released.
    static func reactorWakeAfterShutdown() throws -> HazardOutcome {
        let directory = try HZ.makeTemporaryDirectory("wake-after-shutdown")
        defer { try? FileManager.default.removeItem(at: directory) }

        var runtime: EventedIORuntime? = try EventedIORuntime()
        let pipe = runtime!.wakePipeDescriptorsForTesting

        guard let readIdentity = fifoIdentity(pipe.read),
              let writeIdentity = fifoIdentity(pipe.write)
        else {
            return .inconclusive("wake pipe descriptors were not FIFOs before shutdown")
        }

        HZ.step("shutdown, then let the reactor thread exit")
        runtime!.shutdown()
        usleep(50_000)

        guard fifoIdentity(pipe.read) == readIdentity,
              fifoIdentity(pipe.write) == writeIdentity
        else {
            return .present("shutdown closed or replaced the wake pipe while the reactor was still reachable")
        }

        HZ.step("open fresh files, then wake 1000 times after shutdown")
        var fresh: [Int32] = []
        defer { fresh.forEach { _ = Darwin.close($0) } }

        for index in 0..<16 {
            let descriptor = Darwin.open(
                directory.appendingPathComponent("fresh-\(index)").path,
                O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC,
                mode_t(0o600)
            )

            guard descriptor >= 0 else {
                return .inconclusive("could not open fresh file: errno \(errno)")
            }

            if descriptor == pipe.read || descriptor == pipe.write {
                return .present("a freshly opened file received wake-pipe descriptor \(descriptor) after shutdown")
            }

            fresh.append(descriptor)
        }

        for _ in 0..<1_000 {
            runtime!.wakeForTesting()
        }

        for descriptor in fresh {
            var info = stat()

            if Darwin.fstat(descriptor, &info) == 0, info.st_size > 0 {
                return .present("a late wake() wrote into freshly opened descriptor \(descriptor)")
            }
        }

        guard fifoIdentity(pipe.write) == writeIdentity else {
            return .present("wake pipe changed identity during late wake() calls")
        }

        HZ.step("release the runtime")
        runtime = nil

        for _ in 0..<100 {
            if fifoIdentity(pipe.read) != readIdentity,
               fifoIdentity(pipe.write) != writeIdentity
            {
                return .absent(
                    "wake pipe stayed owned through shutdown and 1000 late wakes; no fresh descriptor was affected; closed on release"
                )
            }

            usleep(10_000)
        }

        return .inconclusive("wake pipe was still open 1 s after the runtime was released")
    }

    private static func fifoIdentity(
        _ descriptor: Int32
    ) -> String? {
        var info = stat()

        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO)
        else {
            return nil
        }

        return "\(info.st_dev):\(info.st_ino)"
    }

    /// Forces the exact #3a interleaving instead of waiting for scheduler luck:
    /// an in-flight wake is paused immediately before its write, shutdown is allowed
    /// to finish completely, the external runtime reference is released, and fresh
    /// files are opened before the wake is permitted to continue.
    static func reactorInflightWakeShutdown() throws -> HazardOutcome {
        let directory = try HZ.makeTemporaryDirectory("inflight-wake-shutdown")
        defer { try? FileManager.default.removeItem(at: directory) }

        var runtime: EventedIORuntime? = try EventedIORuntime()
        let pipe = runtime!.wakePipeDescriptorsForTesting

        guard let readIdentity = fifoIdentity(pipe.read),
              let writeIdentity = fifoIdentity(pipe.write)
        else {
            return .present("wake pipe descriptors were not FIFOs before the forced interleaving")
        }

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)

        let wakeThread = Thread { [runtime = runtime!] in
            runtime.wakeForTesting {
                entered.signal()
                HZ.waitBlocking(release)
            }

            finished.signal()
        }

        HZ.step("enter wake and pause immediately before its write")
        wakeThread.start()
        HZ.waitBlocking(entered)

        HZ.step("shutdown while the wake remains suspended")
        runtime!.shutdown()

        while !runtime!.reactorThreadFinishedForTesting {
            usleep(1_000)
        }

        guard fifoIdentity(pipe.read) == readIdentity,
              fifoIdentity(pipe.write) == writeIdentity
        else {
            release.signal()
            HZ.waitBlocking(finished)
            return .present("reactor shutdown closed or replaced its wake pipe while a wake was still in flight")
        }

        HZ.step("drop the external runtime reference while the wake still owns the runtime")
        runtime = nil

        var fresh: [Int32] = []
        defer { fresh.forEach { _ = Darwin.close($0) } }

        for index in 0..<32 {
            let descriptor = Darwin.open(
                directory.appendingPathComponent("fresh-\(index)").path,
                O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC,
                mode_t(0o600)
            )

            guard descriptor >= 0 else {
                release.signal()
                HZ.waitBlocking(finished)
                return .present("could not open fresh descriptor during forced interleaving: errno \(errno)")
            }

            if descriptor == pipe.read || descriptor == pipe.write {
                release.signal()
                HZ.waitBlocking(finished)
                _ = Darwin.close(descriptor)
                return .present("wake-pipe descriptor \(descriptor) was reused while wake() was still in flight")
            }

            fresh.append(descriptor)
        }

        guard fifoIdentity(pipe.read) == readIdentity,
              fifoIdentity(pipe.write) == writeIdentity
        else {
            release.signal()
            HZ.waitBlocking(finished)
            return .present("wake pipe lost its identity before the suspended wake was released")
        }

        HZ.step("release the suspended wake")
        release.signal()
        HZ.waitBlocking(finished)

        for descriptor in fresh {
            var info = stat()

            guard Darwin.fstat(descriptor, &info) == 0 else {
                return .present("fresh descriptor \(descriptor) became invalid during the forced interleaving")
            }

            if info.st_size > 0 {
                return .present("the in-flight wake wrote into freshly opened descriptor \(descriptor)")
            }
        }

        return .absent(
            "forced in-flight wake kept the original wake pipe alive across completed shutdown and external runtime release; no descriptor was reused or written"
        )
    }
}

#endif
