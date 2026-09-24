#if canImport(Darwin)
import Darwin
import Foundation
import IO

/// V0 hazard characterization.
///
/// Every probe runs in its own child process (`tio_hazard --hazard-probe <id>`).
/// Crashes, SIGPIPE deaths, traps, and hangs are therefore observations rather
/// than harness failures. Verdicts describe *current* behavior:
///
/// - `present`: the audited hazard was reproduced;
/// - `absent`: the fixture ran and the hazard did not occur;
/// - `inconclusive`: the fixture could not be established, or a stress probe
///   did not observe a structurally proven race.
///
/// This pass never mutates production sources and always exits 0.
enum HazardVerdict: String {
    case present
    case absent
    case inconclusive
}

struct HazardOutcome {
    let verdict: HazardVerdict
    let detail: String

    static func present(_ detail: String) -> Self {
        .init(verdict: .present, detail: detail)
    }

    static func absent(_ detail: String) -> Self {
        .init(verdict: .absent, detail: detail)
    }

    static func inconclusive(_ detail: String) -> Self {
        .init(verdict: .inconclusive, detail: detail)
    }
}

struct HazardProbe {
    let id: String
    let finding: String
    let timeoutSeconds: Double
    let onSignal: (Int32) -> HazardOutcome
    let onTimeout: HazardOutcome
    let body: () async throws -> HazardOutcome

    init(
        _ id: String,
        finding: String,
        timeoutSeconds: Double = 10,
        onSignal: @escaping (Int32) -> HazardOutcome = { signal in
            .present("child terminated by \(HZ.signalName(signal))")
        },
        onTimeout: HazardOutcome = .present("child did not finish before its timeout (hang)"),
        body: @escaping () async throws -> HazardOutcome
    ) {
        self.id = id
        self.finding = finding
        self.timeoutSeconds = timeoutSeconds
        self.onSignal = onSignal
        self.onTimeout = onTimeout
        self.body = body
    }
}

extension TestIO {
    package static func runHazard(
        arguments: [String]
    ) async throws {
        if arguments.count >= 2,
           arguments[0] == HZ.childFlag
        {
            await HazardRunner.runChild(
                id: arguments[1]
            )
            return
        }

        _ = try HazardRunner.runParent(
            verbose: arguments.contains("--verbose")
                || arguments.contains("-v"),
            only: nil
        )
    }

    /// Regression gate over repaired findings: runs only
    /// `HazardRunner.repairedProbeIDs` and exits 1 unless every one is ABSENT.
    package static func runHazardGate(
        arguments: [String]
    ) async throws {
        if arguments.count >= 2,
           arguments[0] == HZ.childFlag
        {
            await HazardRunner.runChild(
                id: arguments[1]
            )
            return
        }

        let gated = Set(HazardRunner.repairedProbeIDs)
        let outcomes = try HazardRunner.runParent(
            verbose: arguments.contains("--verbose")
                || arguments.contains("-v"),
            only: gated
        )
        let regressions = HazardRunner.repairedProbeIDs.filter {
            outcomes[$0]?.verdict != .absent
        }

        print("")

        guard regressions.isEmpty else {
            print("tio_hazard_gate: FAILED — repaired hazard(s) not ABSENT: \(regressions.joined(separator: ", "))")
            Darwin.exit(1)
        }

        print("tio_hazard_gate: passed — \(gated.count) repaired hazard(s) remain ABSENT")
    }
}

enum HazardRunner {
    /// Probes whose findings have been repaired. `tio_hazard_gate` fails when
    /// any of them reports anything other than ABSENT.
    ///
    /// Cluster 1 (memory and process safety): #1, #2, #3b, #8b.
    /// Cluster 2 (execution): #4, #5, #6. #3a stays ungated: its stress probe can
    /// only report PRESENT or INCONCLUSIVE, never ABSENT.
    /// Cluster 3 (progress accounting): #7a, #9, #10.
    static let repairedProbeIDs: [String] = [
        "bounded-stream-wrapped-ring",
        "socket-peer-close-vector-write",
        "socket-peer-close-scalar-send",
        "socket-peer-close-after-adopt",
        "pipe-destination-peer-close",
        "socket-after-close-fd-reuse",
        "scanner-kernel-negative-index",
        "scanner-kernel-past-end-index",
        "scanner-kernel-backward-index",
        "wait-negative-fd-blocking",
        "wait-negative-fd-blocking-deadline",
        "wait-negative-fd-evented",
        "wait-empty-interest-blocking",
        "wait-empty-interest-evented",
        "cross-runtime-deadline",
        "computed-blocking-runtime-deadline",
        "run-blocking-cancellation-completion",
        "destination-progress-before-error",
        "darwin-large-direct-write",
        "scanner-throw-progress",
    ]

    static var probes: [HazardProbe] {
        HZStreamProbes.probes
            + HZExecutionProbes.probes
            + HZScanProbes.probes
            + HZSystemProbes.probes
    }

    static func runChild(
        id: String
    ) async {
        guard let probe = probes.first(where: { $0.id == id }) else {
            HZ.emit("HAZARD-VERDICT inconclusive")
            HZ.emit("HAZARD-DETAIL unknown probe \(id)")
            return
        }

        let outcome: HazardOutcome

        do {
            outcome = try await probe.body()
        } catch {
            outcome = .inconclusive(
                "probe threw before reaching a verdict: \(error)"
            )
        }

        HZ.emit("HAZARD-VERDICT \(outcome.verdict.rawValue)")
        HZ.emit("HAZARD-DETAIL \(HZ.oneLine(outcome.detail))")
    }

    @discardableResult
    static func runParent(
        verbose: Bool,
        only: Set<String>?
    ) throws -> [String: HazardOutcome] {
        let executable = try HZ.currentExecutable()
        let all = probes.filter { only?.contains($0.id) ?? true }

        if only == nil {
            print("tio_hazard · hazard characterization")
            print("mode: characterize only; verdicts describe current behavior; exit status is always 0")
        } else {
            print("tio_hazard_gate · repaired-hazard regression gate")
            print("mode: every gated probe must be ABSENT")
        }

        print("probes: \(all.count)")
        print("")

        var counts: [HazardVerdict: Int] = [:]
        var outcomes: [String: HazardOutcome] = [:]

        for probe in all {
            let outcome = try evaluate(
                probe,
                executable: executable,
                verbose: verbose
            )

            counts[outcome.verdict, default: 0] += 1
            outcomes[probe.id] = outcome

            let tag = outcome.verdict.rawValue.uppercased()
                .padding(toLength: 12, withPad: " ", startingAt: 0)
            let finding = probe.finding
                .padding(toLength: 5, withPad: " ", startingAt: 0)

            print("[\(tag)] \(finding) \(probe.id) — \(outcome.detail)")
        }

        print("")
        print(
            "summary: present \(counts[.present, default: 0])"
                + " · absent \(counts[.absent, default: 0])"
                + " · inconclusive \(counts[.inconclusive, default: 0])"
        )

        return outcomes
    }

    static func evaluate(
        _ probe: HazardProbe,
        executable: URL,
        verbose: Bool
    ) throws -> HazardOutcome {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tio-hazard-\(probe.id)-\(UUID().uuidString).log"
            )

        guard FileManager.default.createFile(
            atPath: logURL.path,
            contents: nil
        ) else {
            return .inconclusive(
                "could not create probe log at \(logURL.path)"
            )
        }

        defer {
            try? FileManager.default.removeItem(at: logURL)
        }

        let log = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = executable
        process.arguments = [HZ.childFlag, probe.id]
        process.standardOutput = log
        process.standardError = log

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        try process.run()
        try? log.close()

        var timedOut = false
        let timeout = DispatchTime.now()
            + .milliseconds(Int(probe.timeoutSeconds * 1000))

        if finished.wait(timeout: timeout) == .timedOut {
            timedOut = true
            process.terminate()

            if finished.wait(timeout: .now() + .seconds(2)) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }

        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        if verbose {
            for line in lines {
                print("    │ \(line)")
            }
        }

        let lastStep = lines
            .last(where: { $0.hasPrefix("HAZARD-STEP ") })
            .map { String($0.dropFirst("HAZARD-STEP ".count)) }
        let context = lastStep.map { " [last step: \($0)]" } ?? ""

        if timedOut {
            return .init(
                verdict: probe.onTimeout.verdict,
                detail: probe.onTimeout.detail + context
            )
        }

        if process.terminationReason == .uncaughtSignal {
            let mapped = probe.onSignal(process.terminationStatus)
            let tail = lines
                .filter { !$0.hasPrefix("HAZARD-") }
                .suffix(2)
                .joined(separator: " / ")

            return .init(
                verdict: mapped.verdict,
                detail: mapped.detail
                    + context
                    + (tail.isEmpty ? "" : " [output: \(HZ.oneLine(tail))]")
            )
        }

        guard let verdictLine = lines.last(where: { $0.hasPrefix("HAZARD-VERDICT ") }),
              let verdict = HazardVerdict(
                rawValue: String(verdictLine.dropFirst("HAZARD-VERDICT ".count))
              )
        else {
            return .inconclusive(
                "child exited with status \(process.terminationStatus) without a verdict\(context)"
            )
        }

        let detail = lines
            .last(where: { $0.hasPrefix("HAZARD-DETAIL ") })
            .map { String($0.dropFirst("HAZARD-DETAIL ".count)) }
            ?? ""

        return .init(
            verdict: verdict,
            detail: detail
        )
    }
}

/// Probe-local helpers. Everything here is deliberately raw POSIX so the
/// fixtures do not depend on the code paths under characterization.
enum HZ {
    static let childFlag = "--hazard-probe"

    /// Unbuffered stdout write so progress survives a crashing child.
    static func emit(
        _ line: String
    ) {
        var text = line + "\n"
        text.withUTF8 { buffer in
            _ = Darwin.write(STDOUT_FILENO, buffer.baseAddress, buffer.count)
        }
    }

    static func step(
        _ description: String
    ) {
        emit("HAZARD-STEP \(description)")
    }

    static func oneLine(
        _ text: String
    ) -> String {
        text.replacingOccurrences(of: "\n", with: " ⏎ ")
    }

    static func signalName(
        _ signal: Int32
    ) -> String {
        switch signal {
        case SIGPIPE: return "SIGPIPE (13)"
        case SIGTRAP: return "SIGTRAP (5, Swift runtime trap)"
        case SIGILL: return "SIGILL (4, Swift runtime trap)"
        case SIGSEGV: return "SIGSEGV (11)"
        case SIGBUS: return "SIGBUS (10)"
        case SIGABRT: return "SIGABRT (6)"
        case SIGKILL: return "SIGKILL (9)"
        case SIGTERM: return "SIGTERM (15)"
        default: return "signal \(signal)"
        }
    }

    static func currentExecutable() throws -> URL {
        if let url = Bundle.main.executableURL {
            return url
        }

        guard let first = ProcessInfo.processInfo.arguments.first else {
            throw TestFailure(message: "cannot locate the tio_hazard executable")
        }

        return URL(fileURLWithPath: first).standardizedFileURL
    }

    static func milliseconds(
        _ duration: Duration
    ) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1e15
    }

    static func format(
        _ milliseconds: Double
    ) -> String {
        String(format: "%.1f", milliseconds)
    }

    static func socketPair() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [-1, -1]
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }

        guard result == 0 else {
            throw TestFailure(message: "socketpair failed with errno \(errno)")
        }

        return (descriptors[0], descriptors[1])
    }

    static func pipePair() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [-1, -1]
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress)
        }

        guard result == 0 else {
            throw TestFailure(message: "pipe failed with errno \(errno)")
        }

        return (descriptors[0], descriptors[1])
    }

    static func close(
        _ descriptor: Int32
    ) {
        _ = Darwin.close(descriptor)
    }

    static func openDescriptors() -> Set<Int32> {
        var result = Set<Int32>()
        let limit = min(Darwin.getdtablesize(), 4096)

        for descriptor in 0..<limit
            where Darwin.fcntl(descriptor, F_GETFD) != -1
        {
            result.insert(descriptor)
        }

        return result
    }

    static func isCloseOnExec(
        _ descriptor: Int32
    ) -> Bool {
        let flags = Darwin.fcntl(descriptor, F_GETFD)
        return flags != -1 && (flags & FD_CLOEXEC) != 0
    }

    static func makeTemporaryDirectory(
        _ label: String
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tio-hazard-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )

        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )

        return url
    }

    static func writeFile(
        _ url: URL,
        contents: String,
        mode: Int
    ) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data(contents.utf8)
        ) else {
            throw TestFailure(message: "could not create \(url.path)")
        }

        guard Darwin.chmod(url.path, mode_t(mode)) == 0 else {
            throw TestFailure(message: "chmod \(url.path) failed with errno \(errno)")
        }
    }

    static func permissionBits(
        _ path: String
    ) -> Int? {
        var info = stat()

        guard Darwin.lstat(path, &info) == 0 else {
            return nil
        }

        return Int(info.st_mode & mode_t(0o777))
    }

    /// Synchronous semaphore wait kept out of async bodies.
    static func waitBlocking(
        _ semaphore: DispatchSemaphore
    ) {
        semaphore.wait()
    }
}

/// Lock-protected flags and counter shared with probe threads.
final class HZState: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: Set<String> = []
    private var counter = 0

    func set(
        _ flag: String
    ) {
        lock.withLock {
            _ = flags.insert(flag)
        }
    }

    func isSet(
        _ flag: String
    ) -> Bool {
        lock.withLock {
            flags.contains(flag)
        }
    }

    func increment() {
        lock.withLock {
            counter += 1
        }
    }

    var count: Int {
        lock.withLock {
            counter
        }
    }
}

#else

import IO

extension TestIO {
    package static func runHazard(
        arguments: [String]
    ) async throws {
        _ = arguments
        print("tio_hazard: V0 characterization currently targets Darwin only")
    }

    package static func runHazardGate(
        arguments: [String]
    ) async throws {
        _ = arguments
        print("tio_hazard_gate: currently targets Darwin only")
    }
}

#endif
