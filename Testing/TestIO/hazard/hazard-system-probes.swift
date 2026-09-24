#if canImport(Darwin)
import Darwin
import Foundation
import IO

/// Process-state and filesystem probes: audit finding #11 plus the
/// filesystem items (descriptor-depth removal, replace permission window).
enum HZSystemProbes {
    static var probes: [HazardProbe] {
        [
            .init(
                "close-on-exec-descriptors",
                finding: "#11",
                body: { try closeOnExecDescriptors() }
            ),
            .init(
                "deep-tree-remove-descriptor-limit",
                finding: "fs",
                timeoutSeconds: 30,
                body: { try deepTreeRemoveUnderDescriptorLimit() }
            ),
            .init(
                "replace-permission-window",
                finding: "fs",
                timeoutSeconds: 60,
                onTimeout: .inconclusive("stress probe exceeded its time budget"),
                body: { try replacePermissionWindow() }
            ),
        ]
    }

    static func closeOnExecDescriptors() throws -> HazardOutcome {
        let directory = try HZ.makeTemporaryDirectory("cloexec")
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourcePath = directory.appendingPathComponent("source.bin").path
        let destinationPath = directory.appendingPathComponent("destination.bin").path

        guard FileManager.default.createFile(
            atPath: sourcePath,
            contents: Data([1, 2, 3])
        ) else {
            return .inconclusive("could not create the source fixture")
        }

        var findings: [String] = []
        var leaking: [String] = []

        func record(
            _ component: String,
            _ descriptors: Set<Int32>
        ) {
            guard !descriptors.isEmpty else {
                findings.append("\(component): no new descriptor observed")
                return
            }

            for descriptor in descriptors.sorted() {
                let closeOnExec = HZ.isCloseOnExec(descriptor)
                findings.append("\(component) fd \(descriptor) FD_CLOEXEC=\(closeOnExec)")

                if !closeOnExec {
                    leaking.append(component)
                }
            }
        }

        HZ.step("SystemFileSource")
        var before = HZ.openDescriptors()
        var source = try SystemFileSource(path: sourcePath)
        record("SystemFileSource", HZ.openDescriptors().subtracting(before))
        try source.close()

        HZ.step("SystemFileDestination")
        before = HZ.openDescriptors()
        var destination = try SystemFileDestination(
            path: destinationPath,
            mode: .create
        )
        record("SystemFileDestination", HZ.openDescriptors().subtracting(before))
        try destination.close()

        HZ.step("EventedIORuntime")
        before = HZ.openDescriptors()
        let runtime = try EventedIORuntime()
        record("EventedIORuntime wake pipe", HZ.openDescriptors().subtracting(before))
        runtime.shutdown()

        let detail = findings.joined(separator: "; ")

        if !leaking.isEmpty {
            let components = Array(Set(leaking)).sorted().joined(separator: ", ")
            return .present("descriptors inheritable across exec from: \(components) — \(detail)")
        }

        return .absent(detail)
    }

    /// Builds a depth-120 tree, lowers the soft descriptor limit to 64, then
    /// runs the native recursive removal, which keeps one DIR* per level.
    static func deepTreeRemoveUnderDescriptorLimit() throws -> HazardOutcome {
        let root = try HZ.makeTemporaryDirectory("deep-remove")
        let depth = 120
        var leaf = root

        for _ in 0..<depth {
            leaf.appendPathComponent("d", isDirectory: true)
        }

        try FileManager.default.createDirectory(
            at: leaf,
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(
            atPath: leaf.appendingPathComponent("leaf.txt").path,
            contents: Data("x".utf8)
        )

        var original = rlimit()

        guard Darwin.getrlimit(RLIMIT_NOFILE, &original) == 0 else {
            try? FileManager.default.removeItem(at: root)
            return .inconclusive("getrlimit failed with errno \(errno)")
        }

        var lowered = original
        lowered.rlim_cur = 64

        guard Darwin.setrlimit(RLIMIT_NOFILE, &lowered) == 0 else {
            try? FileManager.default.removeItem(at: root)
            return .inconclusive("setrlimit failed with errno \(errno)")
        }

        HZ.step("FileSystem.c.remove on a depth-\(depth) tree with soft RLIMIT_NOFILE 64")
        let observation: String
        var failed = false

        do {
            try FileSystem.c.remove(root)
            observation = "remove succeeded"
        } catch {
            failed = true
            observation = "remove threw \(error)"
        }

        var restored = original
        _ = Darwin.setrlimit(RLIMIT_NOFILE, &restored)

        let remains = FileManager.default.fileExists(atPath: root.path)
        try? FileManager.default.removeItem(at: root)

        let detail = "\(observation); tree root still present afterwards: \(remains)"

        if failed {
            return .present(
                "native recursive removal could not complete a depth-\(depth) tree under a 64-descriptor soft limit — \(detail)"
            )
        }

        return .absent(detail)
    }

    /// Original 0600, replacement 0644. An observer thread spins on lstat of
    /// the original path during each native replace.
    static func replacePermissionWindow() throws -> HazardOutcome {
        let directory = try HZ.makeTemporaryDirectory("replace-window")
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = directory.appendingPathComponent("ledger.dat")
        let replacement = directory.appendingPathComponent("ledger.incoming")
        let originalPath = original.path

        try HZ.writeFile(original, contents: "original", mode: 0o600)

        let state = HZState()
        let watcherDone = DispatchSemaphore(value: 0)

        let watcher = Thread {
            while !state.isSet("stop") {
                if HZ.permissionBits(originalPath) == 0o644 {
                    state.increment()
                }
            }

            watcherDone.signal()
        }
        watcher.start()

        let iterations = 300
        var unrestored = 0

        for iteration in 0..<iterations {
            if iteration % 100 == 0 {
                HZ.step("replace iteration \(iteration)")
            }

            try HZ.writeFile(replacement, contents: "replacement \(iteration)", mode: 0o644)
            try FileSystem.c.replace(original, with: replacement)

            if HZ.permissionBits(originalPath) != 0o600 {
                unrestored += 1
                _ = Darwin.chmod(originalPath, mode_t(0o600))
            }
        }

        state.set("stop")
        HZ.waitBlocking(watcherDone)

        let hits = state.count

        if unrestored > 0 {
            return .inconclusive(
                "replace left the original with non-0600 permissions \(unrestored) time(s); window measurement is not meaningful (observer hits: \(hits))"
            )
        }

        if hits > 0 {
            return .present(
                "observer saw the replaced original with the replacement's 0644 mode \(hits) time(s) across \(iterations) replaces before 0600 was re-applied"
            )
        }

        // Before the repair this observer caught the window thousands of times
        // per run; with metadata applied before the swap it no longer exists by
        // construction, so no observation is reported as ABSENT.
        return .absent(
            "no 0644 observation across \(iterations) replaces"
        )
    }
}

#endif
