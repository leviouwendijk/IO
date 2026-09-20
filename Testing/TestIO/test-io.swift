import IO

struct TestFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

struct TestCase {
    let name: String
    let body: () throws -> Void
}

/// Shared verification and benchmark harness for the IO package.
///
/// Executable targets under `Testing/tio_*` compose these domain suites without
/// duplicating benchmark implementations or transport fixtures.
package enum TestIO {
    package static func runAll(
        arguments: [String]
    ) throws {
        if try runSelectionWorkerIfRequested(arguments) {
            return
        }

        try runTests(
            coreTests
                + streamTests
                + scanTests
                + fileTests
                + overheadTests
                + fileSystemTests,
            suite: "tio",
            arguments: arguments
        )
        try runRequestedBenchmark(
            arguments: arguments
        )
    }

    package static func runCore(
        arguments: [String]
    ) throws {
        try runTests(
            coreTests,
            suite: "tio_core",
            arguments: arguments
        )
    }

    package static func runStream(
        arguments: [String]
    ) throws {
        try runTests(
            streamTests,
            suite: "tio_stream",
            arguments: arguments
        )
        try runStreamBenchmarkIfRequested(
            arguments: arguments
        )
    }

    package static func runScan(
        arguments: [String]
    ) throws {
        try runTests(
            scanTests,
            suite: "tio_scan",
            arguments: arguments
        )
        try runScanBenchmarkIfRequested(
            arguments: arguments
        )
    }

    package static func runFile(
        arguments: [String]
    ) throws {
        if try runSelectionWorkerIfRequested(arguments) {
            return
        }

        try runTests(
            fileTests,
            suite: "tio_file",
            arguments: arguments
        )
        try runFileBenchmarkIfRequested(
            arguments: arguments
        )
    }

    package static func runOverhead(
        arguments: [String]
    ) throws {
        try runTests(
            overheadTests,
            suite: "tio_overhead",
            arguments: arguments
        )
        try runOverheadBenchmarkIfRequested(
            arguments: arguments
        )
    }

    package static func runFS(
        arguments: [String]
    ) throws {
        try runTests(
            fileSystemTests,
            suite: "tio_fs",
            arguments: arguments
        )
        try runFileSystemBenchmarkIfRequested(
            arguments: arguments
        )
    }

    private static var coreTests: [TestCase] {
        [
        .init(name: "refined-values", body: testRefinedValues),
        .init(name: "source-borrow-consume", body: testSourceBorrowConsume),
        .init(name: "source-tail-refill", body: testSourceTailRefill),
        .init(name: "source-buffer-full-state", body: testSourceBufferFull),
        .init(name: "source-unavailable", body: testSourceUnavailable),
        .init(name: "source-consume-bounds", body: testSourceConsumeBounds),
        .init(name: "ownership-compile-rejections", body: testOwnershipCompileRejections),
        .init(name: "source-move-preserves-state", body: testSourceMovePreservesState),
        .init(name: "destination-move-preserves-state", body: testDestinationMovePreservesState),
        .init(name: "destination-tiny-write-buffering", body: testDestinationTinyWrites),
        .init(name: "destination-large-write-bypass", body: testDestinationLargeWriteBypass),
        .init(name: "destination-short-drain", body: testDestinationShortDrain),
        .init(name: "destination-partial-unavailable", body: testDestinationPartialUnavailable),
        .init(name: "stream-memory-memory", body: testStream),
        .init(name: "stream-limit", body: testStreamLimit),
        .init(name: "discard-limit", body: testDiscard),
        .init(name: "transform-dual-role", body: testTransform),
        .init(name: "source-overreport-contract", body: testSourceOverreport),
        .init(name: "destination-overreport-contract", body: testDestinationOverreport),
        ]
    }

    private static var streamTests: [TestCase] {
        [
        .init(name: "stream-buffer-memmove-compaction", body: testStreamBufferMemmoveCompaction),
        .init(name: "destination-exact-capacity-bypass-policy", body: testDestinationExactCapacityBypassPolicy),
        .init(name: "ring-buffer-wraparound", body: testRingBufferWraparound),
        .init(name: "posix-vector-io", body: testPOSIXVectorIO),
        .init(name: "scripted-nonblocking-backpressure", body: testScriptedNonblockingBackpressure),
        .init(name: "deterministic-readiness", body: testDeterministicReadiness),
        .init(name: "nonblocking-socket-backend", body: testNonblockingSocketBackend),
        .init(name: "ring-socket-streams", body: testRingSocketStreams),
        .init(name: "deterministic-stream-decomposition-backends", body: testDeterministicStreamDecompositionBackends),
        .init(name: "dispatch-storage-decomposition-representations", body: testDispatchStorageDecompositionRepresentations),
        ]
    }

    private static var scanTests: [TestCase] {
        [
        .init(name: "scanner-probe-equivalence", body: testScannerProbeEquivalence),
        .init(name: "scanner-hybrid-kernel-equivalence", body: testScannerHybridKernelEquivalence),
        .init(name: "byte-match-kernel-equivalence", body: testByteMatchKernelEquivalence),
        .init(name: "byte-line-scanner-swappable-kernel", body: testByteLineScannerSwappableKernel),
        .init(name: "scanner-randomized-stop-resume", body: testScannerRandomizedStopResume),
        .init(name: "scanner-move-preserves-fragment-state", body: testScannerMovePreservesFragmentState),
        ]
    }

    private static var fileTests: [TestCase] {
        [
        .init(name: "system-file-source", body: testSystemFileSource),
        .init(name: "selection-unicode-fragmentation", body: testSelectionUnicodeFragmentation),
        .init(name: "selection-invalid-utf8", body: testSelectionInvalidUTF8),
        .init(name: "selection-long-line-bounds", body: testSelectionLongLineBounds),
        .init(name: "selection-variable-fragmentation", body: testSelectionVariableFragmentation),
        .init(name: "selection-randomized-properties", body: testSelectionRandomizedProperties),
        .init(name: "system-file-descriptor-lifecycle", body: testSystemFileDescriptorLifecycle),
        .init(name: "system-file-explicit-close", body: testSystemFileExplicitCloseIsIdempotent),
        ]
    }

    private static var overheadTests: [TestCase] {
        [
        .init(name: "synthetic-overhead-harness-equivalence", body: testSyntheticOverheadHarnessEquivalence),
        ]
    }

    private static var fileSystemTests: [TestCase] {
        [
        .init(name: "filesystem-direct-entry-kinds", body: testFileSystemDirectEntryKinds),
        .init(name: "filesystem-recursive-wide-deep", body: testFileSystemRecursiveWideAndDeep),
        .init(name: "filesystem-inspector-semantics", body: testFileInspectorSemantics),
        .init(name: "directory-inspector-semantics", body: testDirectoryInspectorSemantics),
        .init(name: "filesystem-missing-and-error-shape", body: testFileSystemMissingAndErrorShape),
        .init(name: "filesystem-baseline-instrumentation", body: testFileSystemBaselineInstrumentation),
        .init(name: "filesystem-c-equivalence", body: testCFileSystemEquivalence),
        .init(name: "filesystem-native-path-substrate", body: testNativePathSubstrate),
        .init(name: "filesystem-c-directory-inspector-strategy", body: testCDirectoryInspectorStrategy),
        .init(name: "filesystem-error-model", body: testFileSystemErrorModel),
        .init(name: "filesystem-mutation-create-remove-equivalence", body: testFileSystemMutationCreateRemoveEquivalence),
        .init(name: "filesystem-mutation-copy-equivalence", body: testFileSystemMutationCopyEquivalence),
        .init(name: "filesystem-mutation-move-equivalence", body: testFileSystemMutationMoveEquivalence),
        .init(name: "filesystem-mutation-replace-equivalence", body: testFileSystemMutationReplaceEquivalence),
        .init(name: "filesystem-mutation-failure-postconditions", body: testFileSystemMutationFailurePostconditions),
        .init(name: "filesystem-resolution-reference-equivalence", body: testFileSystemResolutionReferenceEquivalence),
        .init(name: "filesystem-resolution-native-candidate-equivalence", body: testNativeResolutionCandidates),
        .init(name: "filesystem-resolution-component-adaptive-equivalence", body: testComponentAdaptiveResolutionCandidate),
        .init(name: "filesystem-resolution-readlink-dispatch-equivalence", body: testReadlinkDispatchResolutionCandidate),
        ]
    }

    private static func runTests(
        _ tests: [TestCase],
        suite: String,
        arguments: [String]
    ) throws {
        let options = Set(arguments)
        let verbose = options.contains("--verbose")
            || options.contains("-v")

        if verbose {
            print(suite)
            print("tests: \(tests.count)")
            print("")
        }

        var failures: [String] = []

        for test in tests {
            if verbose {
                print("[RUN ] \(test.name)")
            }

            do {
                try test.body()

                if verbose {
                    print("[PASS] \(test.name)")
                }
            } catch {
                let failure = "\(test.name): \(error)"
                failures.append(failure)
                print("[FAIL] \(failure)")
            }
        }

        print("")
        print("\(suite): \(tests.count - failures.count)/\(tests.count) passed")

        guard failures.isEmpty else {
            throw TestFailure(
                message: "\(failures.count) \(suite) test(s) failed"
            )
        }
    }

    private static func runSelectionWorkerIfRequested(
        _ arguments: [String]
    ) throws -> Bool {
        guard arguments.first == "--benchmark-worker" else {
            return false
        }

        try runSelectionBenchmarkWorker(
            arguments: arguments
        )
        return true
    }

    private static func runRequestedBenchmark(
        arguments: [String]
    ) throws {
        let options = Set(arguments)

        if options.contains("--vector-io")
            || options.contains("--vector-io-heavy")
            || options.contains("--deterministic-stream-decompose")
            || options.contains("--deterministic-stream-decompose-heavy")
            || options.contains("--dispatch-storage-decompose")
            || options.contains("--dispatch-storage-decompose-heavy")
            || options.contains("--ring-socket-decompose")
            || options.contains("--ring-socket-decompose-heavy")
            || options.contains("--ring-socket-sweep")
            || options.contains("--ring-socket-sweep-heavy")
            || options.contains("--ring-socket")
            || options.contains("--ring-socket-heavy")
        {
            try runStreamBenchmarkIfRequested(
                arguments: arguments
            )
            return
        }

        if options.contains("--scanner-kernel")
            || options.contains("--scanner-kernel-heavy")
            || options.contains("--scanner-overhead")
            || options.contains("--scanner-overhead-heavy")
        {
            try runScanBenchmarkIfRequested(
                arguments: arguments
            )
            return
        }

        if options.contains("--io-overhead-synthetic")
            || options.contains("--io-overhead-synthetic-heavy")
            || options.contains("--io-overhead")
            || options.contains("--io-overhead-heavy")
        {
            try runOverheadBenchmarkIfRequested(
                arguments: arguments
            )
            return
        }

        if options.contains("--filesystem-baseline")
            || options.contains("--filesystem-baseline-heavy")
            || options.contains("--filesystem-compare")
            || options.contains("--filesystem-compare-heavy")
            || options.contains("--filesystem-enumeration-decompose")
            || options.contains("--filesystem-enumeration-decompose-heavy")
            || options.contains("--filesystem-mutation-compare")
            || options.contains("--filesystem-mutation-compare-heavy")
            || options.contains("--filesystem-resolve-characterize")
            || options.contains("--filesystem-resolve-compare")
            || options.contains("--filesystem-resolve-compare-heavy")
            || options.contains("--filesystem-resolve-decompose")
            || options.contains("--filesystem-resolve-decompose-heavy")
            || options.contains("--filesystem-resolve-native-candidates")
            || options.contains("--filesystem-resolve-native-candidates-heavy")
            || options.contains("--filesystem-resolve-component-adaptive")
            || options.contains("--filesystem-resolve-component-adaptive-heavy")
            || options.contains("--filesystem-resolve-readlink-dispatch")
            || options.contains("--filesystem-resolve-readlink-dispatch-heavy")
        {
            try runFileSystemBenchmarkIfRequested(
                arguments: arguments
            )
            return
        }

        try runFileBenchmarkIfRequested(
            arguments: arguments
        )
    }

    private static func runStreamBenchmarkIfRequested(
        arguments: [String]
    ) throws {
        let options = Set(arguments)

        if options.contains("--vector-io")
            || options.contains("--vector-io-heavy")
        {
            try runVectorIOBenchmarks(
                heavy: options.contains("--vector-io-heavy")
            )
            return
        }

        if options.contains("--dispatch-storage-decompose")
            || options.contains("--dispatch-storage-decompose-heavy")
        {
            try runDispatchStorageDecompositionBenchmarks(
                heavy: options.contains("--dispatch-storage-decompose-heavy")
            )
            return
        }

        if options.contains("--deterministic-stream-decompose")
            || options.contains("--deterministic-stream-decompose-heavy")
        {
            try runDeterministicStreamDecompositionBenchmarks(
                heavy: options.contains("--deterministic-stream-decompose-heavy")
            )
            return
        }

        if options.contains("--ring-socket-decompose")
            || options.contains("--ring-socket-decompose-heavy")
        {
            try runRingSocketDecompositionBenchmarks(
                heavy: options.contains("--ring-socket-decompose-heavy")
            )
            return
        }

        if options.contains("--ring-socket-sweep")
            || options.contains("--ring-socket-sweep-heavy")
        {
            try runRingSocketSweepBenchmarks(
                heavy: options.contains("--ring-socket-sweep-heavy")
            )
            return
        }

        if options.contains("--ring-socket")
            || options.contains("--ring-socket-heavy")
        {
            try runRingSocketBenchmarks(
                heavy: options.contains("--ring-socket-heavy")
            )
        }
    }

    private static func runScanBenchmarkIfRequested(
        arguments: [String]
    ) throws {
        let options = Set(arguments)

        if options.contains("--scanner-kernel")
            || options.contains("--scanner-kernel-heavy")
        {
            try runScannerHybridKernelBenchmarks(
                heavy: options.contains("--scanner-kernel-heavy")
            )
            return
        }

        if options.contains("--scanner-overhead")
            || options.contains("--scanner-overhead-heavy")
        {
            try runScannerOverheadBenchmarks(
                heavy: options.contains("--scanner-overhead-heavy")
            )
        }
    }

    private static func runFileBenchmarkIfRequested(
        arguments: [String]
    ) throws {
        let options = Set(arguments)

        if options.contains("--benchmark")
            || options.contains("--benchmark-heavy")
        {
            try runSelectionBenchmarks(
                verbose: options.contains("--verbose")
                    || options.contains("-v"),
                heavy: options.contains("--benchmark-heavy")
            )
        }
    }

    private static func runFileSystemBenchmarkIfRequested(
        arguments: [String]
    ) throws {
        let options = Set(arguments)

        if options.contains("--filesystem-resolve-characterize") {
            try runFileSystemResolutionCharacterization()
            return
        }

        if options.contains("--filesystem-resolve-readlink-dispatch")
            || options.contains("--filesystem-resolve-readlink-dispatch-heavy")
        {
            try runReadlinkDispatchResolutionBenchmarks(
                heavy:
                    options.contains(
                        "--filesystem-resolve-readlink-dispatch-heavy"
                    )
            )
            return
        }

        if options.contains("--filesystem-resolve-component-adaptive")
            || options.contains("--filesystem-resolve-component-adaptive-heavy")
        {
            try runComponentAdaptiveResolutionBenchmarks(
                heavy:
                    options.contains(
                        "--filesystem-resolve-component-adaptive-heavy"
                    )
            )
            return
        }

        if options.contains("--filesystem-resolve-native-candidates")
            || options.contains("--filesystem-resolve-native-candidates-heavy")
        {
            try runNativeResolutionCandidateBenchmarks(
                heavy:
                    options.contains(
                        "--filesystem-resolve-native-candidates-heavy"
                    )
            )
            return
        }

        if options.contains("--filesystem-resolve-decompose")
            || options.contains("--filesystem-resolve-decompose-heavy")
        {
            try runFileSystemResolutionDecompositionBenchmarks(
                heavy:
                    options.contains(
                        "--filesystem-resolve-decompose-heavy"
                    )
            )
            return
        }

        if options.contains("--filesystem-resolve-compare")
            || options.contains("--filesystem-resolve-compare-heavy")
        {
            try runFileSystemResolutionComparisonBenchmarks(
                heavy:
                    options.contains(
                        "--filesystem-resolve-compare-heavy"
                    )
            )
            return
        }

        if options.contains("--filesystem-mutation-compare")
            || options.contains("--filesystem-mutation-compare-heavy")
        {
            try runFileSystemMutationComparisonBenchmarks(
                heavy:
                    options.contains(
                        "--filesystem-mutation-compare-heavy"
                    )
            )
            return
        }

        if options.contains("--filesystem-enumeration-decompose")
            || options.contains("--filesystem-enumeration-decompose-heavy")
        {
            try runFileSystemEnumerationDecompositionBenchmarks(
                heavy:
                    options.contains(
                        "--filesystem-enumeration-decompose-heavy"
                    )
            )
            return
        }

        if options.contains("--filesystem-compare")
            || options.contains("--filesystem-compare-heavy")
        {
            try runFileSystemComparisonBenchmarks(
                heavy: options.contains("--filesystem-compare-heavy")
            )
            return
        }

        if options.contains("--filesystem-baseline")
            || options.contains("--filesystem-baseline-heavy")
        {
            try runFileSystemBaselineBenchmarks(
                heavy: options.contains("--filesystem-baseline-heavy")
            )
        }
    }

    private static func runOverheadBenchmarkIfRequested(
        arguments: [String]
    ) throws {
        let options = Set(arguments)

        if options.contains("--io-overhead-synthetic")
            || options.contains("--io-overhead-synthetic-heavy")
        {
            try runSyntheticIOOverheadBenchmarks(
                heavy: options.contains("--io-overhead-synthetic-heavy")
            )
            return
        }

        if options.contains("--io-overhead")
            || options.contains("--io-overhead-heavy")
        {
            try runStandaloneIOOverheadBenchmarks(
                heavy: options.contains("--io-overhead-heavy")
            )
        }
    }
}

extension TestIO {
    static func capacity(
        _ value: Int
    ) throws -> BufferCapacity {
        try BufferCapacity(value)
    }

    static func count(
        _ value: Int
    ) throws -> PositiveByteCount {
        try PositiveByteCount(value)
    }

    static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw TestFailure(message: message)
        }
    }

    static func expectEqual<Value: Equatable>(
        _ actual: Value,
        _ expected: Value,
        _ label: String
    ) throws {
        guard actual == expected else {
            throw TestFailure(
                message: "\(label): expected \(expected), got \(actual)"
            )
        }
    }

    static func bufferedBytes(
        _ source: borrowing Source
    ) -> [UInt8] {
        source.withReadableRegions { first, second in
            Array(first) + Array(second)
        }
    }

    static func expectContractError(
        _ expected: StreamContractError,
        _ body: () throws -> Void
    ) throws {
        do {
            try body()
        } catch let error as StreamContractError {
            try expectEqual(error, expected, "contract error")
            return
        }

        throw TestFailure(
            message: "expected contract error \(expected)"
        )
    }
}

private extension TestIO {
    static func testRefinedValues() throws {
        do {
            _ = try PositiveByteCount(0)
            throw TestFailure(message: "zero byte progress must be rejected")
        } catch StreamValueError.non_positive_byte_count(0) {}

        do {
            _ = try BufferCapacity(0)
            throw TestFailure(message: "zero buffer capacity must be rejected")
        } catch StreamValueError.non_positive_buffer_capacity(0) {}
    }

    static func testSourceBorrowConsume() throws {
        let backend = MemorySource(bytes: [1, 2, 3, 4])
        var source = Source(
            backend,
            bufferCapacity: try capacity(8)
        )

        try expectEqual(try source.prepare(), .bytes, "prepare")
        try expectEqual(bufferedBytes(source), [1, 2, 3, 4], "borrowed bytes")
        try expect(source.hasReachedEnd, "final refill should mark end")
        try expect(!source.isExhausted, "buffered final bytes are not exhausted")

        try source.consume(2)
        try expectEqual(bufferedBytes(source), [3, 4], "remaining bytes")

        try source.consume(2)
        try expect(source.isExhausted, "consumed final bytes should exhaust source")
        try expectEqual(try source.prepare(), .end, "end state")
    }

    static func testSourceTailRefill() throws {
        let backend = MemorySource(
            bytes: [10, 11, 12, 13, 14],
            maximumChunkSize: try count(3)
        )
        var source = Source(
            backend,
            bufferCapacity: try capacity(4)
        )

        _ = try source.prepare()
        try expectEqual(bufferedBytes(source), [10, 11, 12], "initial chunk")

        try source.consume(2)
        try expectEqual(try source.requestMore(), .bytes, "tail refill")
        try expectEqual(bufferedBytes(source), [12, 13, 14], "preserved tail")
        try expect(source.hasReachedEnd, "second refill should be final")
    }

    static func testSourceBufferFull() throws {
        var source = Source(
            MemorySource(bytes: [1, 2, 3]),
            bufferCapacity: try capacity(2)
        )

        _ = try source.prepare()
        try expectEqual(try source.requestMore(), .buffer_full, "full source buffer")
        try expectEqual(source.statistics.refillCallCount, 1, "no backend call while full")

        try source.consume(1)
        try expectEqual(try source.requestMore(), .bytes, "refill after consumption")
        try expectEqual(bufferedBytes(source), [2, 3], "compacted refill")
    }

    static func testSourceUnavailable() throws {
        let backend = PausingSource()
        var source = Source(
            backend,
            bufferCapacity: try capacity(4)
        )

        try expectEqual(try source.prepare(), .unavailable, "first source attempt")
        try expectEqual(try source.prepare(), .bytes, "second source attempt")
        try expectEqual(bufferedBytes(source), [9, 8], "resumed source bytes")
    }

    static func testDestinationTinyWrites() throws {
        var destination = Destination(
            MemoryDestination(),
            bufferCapacity: try capacity(4)
        )

        try expectEqual(try destination.write(UInt8(1)), .complete, "byte write")
        try expectEqual(try destination.write([2, 3]), .complete, "small write")
        try expectEqual(destination.inspectBackend().capturedBytes, [], "tiny writes stay north of backend")
        try expectEqual(destination.statistics.drainCallCount, 0, "no drain before flush")
        try expectEqual(destination.bufferedByteCount, 3, "buffered tiny bytes")

        try expectEqual(try destination.flush(), .complete, "flush")
        try expectEqual(destination.inspectBackend().capturedBytes, [1, 2, 3], "flushed bytes")
        try expectEqual(destination.statistics.drainCallCount, 1, "single drain")
        try expectEqual(destination.statistics.flushCallCount, 1, "backend flush")
    }

    static func testDestinationLargeWriteBypass() throws {
        var destination = Destination(
            MemoryDestination(),
            bufferCapacity: try capacity(4)
        )
        let input = (0..<10).map(UInt8.init)

        try expectEqual(try destination.write(input), .complete, "large write")
        try expectEqual(destination.inspectBackend().capturedBytes, input, "direct backend bytes")
        try expectEqual(destination.statistics.drainCallCount, 1, "large write crosses boundary once")
        try expectEqual(destination.bufferedByteCount, 0, "large write bypasses buffer")
    }

    static func testDestinationShortDrain() throws {
        var destination = Destination(
            MemoryDestination(maximumChunkSize: try count(2)),
            bufferCapacity: try capacity(4)
        )

        try expectEqual(try destination.write([10, 11, 12, 13]), .complete, "buffer write")
        try expectEqual(destination.inspectBackend().capturedBytes, [], "exact-capacity write remains buffered")
        try expectEqual(try destination.flush(), .complete, "short-drain flush")
        try expectEqual(destination.inspectBackend().capturedBytes, [10, 11, 12, 13], "short-drain bytes")
        try expectEqual(destination.statistics.drainCallCount, 2, "short-drain calls")
    }

    static func testDestinationPartialUnavailable() throws {
        var destination = Destination(
            OneProgressThenPauseDestination(),
            bufferCapacity: try capacity(4)
        )
        let input = (0..<10).map(UInt8.init)

        let result = try destination.write(input)

        switch result {
        case .partial(let progress):
            try expectEqual(progress.value, 2, "accepted bytes before pause")
        default:
            throw TestFailure(message: "expected partial write, got \(result)")
        }

        try expectEqual(destination.inspectBackend().capturedBytes, [0, 1], "partial destination bytes")
    }

    static func testStream() throws {
        let input = (0..<19).map(UInt8.init)
        var source = Source(
            MemorySource(
                bytes: input,
                maximumChunkSize: try count(3)
            ),
            bufferCapacity: try capacity(4)
        )
        var destination = Destination(
            MemoryDestination(
                maximumChunkSize: try count(2)
            ),
            bufferCapacity: try capacity(5)
        )

        try expectEqual(
            try source.stream(to: &destination),
            .end(transferred: 19),
            "stream result"
        )

        try expectEqual(try destination.flush(), .complete, "stream flush")
        try expectEqual(destination.inspectBackend().capturedBytes, input, "streamed bytes")
    }

    static func testStreamLimit() throws {
        let input = (0..<10).map(UInt8.init)
        var source = Source(
            MemorySource(bytes: input),
            bufferCapacity: try capacity(10)
        )
        var destination = Destination(
            MemoryDestination(),
            bufferCapacity: try capacity(4)
        )

        try expectEqual(
            try source.stream(to: &destination, maximumCount: 6),
            .limit(transferred: 6),
            "bounded stream"
        )

        try expectEqual(
            try source.stream(to: &destination),
            .end(transferred: 4),
            "remaining stream"
        )

        _ = try destination.flush()
        try expectEqual(destination.inspectBackend().capturedBytes, input, "bounded stream bytes")
    }

    static func testDiscard() throws {
        var source = Source(
            MemorySource(
                bytes: (0..<10).map(UInt8.init),
                maximumChunkSize: try count(3)
            ),
            bufferCapacity: try capacity(4)
        )

        try expectEqual(
            try source.discard(maximumCount: 5),
            .limit(discarded: 5),
            "bounded discard"
        )

        try expectEqual(
            try source.discard(maximumCount: 100),
            .end(discarded: 5),
            "discard remainder"
        )
    }

    static func testTransform() throws {
        let input = (0..<9).map(UInt8.init)
        let transform = IdentityTransform(
            maximumDrain: try count(2),
            maximumRefill: try count(3)
        )

        var upstream = Destination(
            transform,
            bufferCapacity: try capacity(4)
        )

        try expectEqual(try upstream.write(input), .complete, "transform input")
        try expectEqual(try upstream.flush(), .complete, "transform flush")

        var downstream = Source(
            transform,
            bufferCapacity: try capacity(5)
        )
        var destination = Destination(
            MemoryDestination(),
            bufferCapacity: try capacity(4)
        )

        try expectEqual(
            try downstream.stream(to: &destination),
            .source_unavailable(transferred: 9),
            "transform waits for finalization"
        )

        _ = try destination.flush()
        try expectEqual(destination.inspectBackend().capturedBytes, input, "transform bytes")

        transform.finishInput()

        try expectEqual(
            try downstream.stream(to: &destination),
            .end(transferred: 0),
            "transform end after finalization"
        )
    }

    static func testSourceOverreport() throws {
        var source = Source(
            OverreportingSource(),
            bufferCapacity: try capacity(1)
        )

        try expectContractError(
            .source_reported_too_many_bytes(
                reported: 2,
                writable: 1
            )
        ) {
            _ = try source.prepare()
        }
    }

    static func testDestinationOverreport() throws {
        var destination = Destination(
            OverreportingDestination(),
            bufferCapacity: try capacity(1)
        )

        try expectContractError(
            .destination_reported_too_many_bytes(
                reported: 3,
                offered: 2
            )
        ) {
            _ = try destination.write([1, 2])
        }
    }
}

private final class PausingSource: SourceBackend {
    private var attempt = 0

    func refill(
        into bytes: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        attempt += 1

        guard attempt > 1 else {
            return .unavailable
        }

        bytes[0] = 9
        bytes[1] = 8

        return .final_bytes(
            try PositiveByteCount(2)
        )
    }
}

private struct OneProgressThenPauseDestination: DestinationBackend, ~Copyable {
    private(set) var bytes: [UInt8] = []
    private var attempt = 0

    mutating func drain(
        _ input: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        attempt += 1

        guard attempt == 1 else {
            return .unavailable
        }

        let count = min(2, input.count)

        for index in 0..<count {
            bytes.append(input[index])
        }

        return .bytes(
            try PositiveByteCount(count)
        )
    }

    mutating func inspect() -> DestinationBackendInspection {
        .init(capturedBytes: bytes)
    }
}

private final class IdentityTransform: SourceBackend, DestinationBackend {
    private var storage: [UInt8] = []
    private var readIndex = 0
    private var finished = false

    private let maximumDrain: PositiveByteCount
    private let maximumRefill: PositiveByteCount

    init(
        maximumDrain: PositiveByteCount,
        maximumRefill: PositiveByteCount
    ) {
        self.maximumDrain = maximumDrain
        self.maximumRefill = maximumRefill
    }

    func drain(
        _ input: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        let count = min(input.count, maximumDrain.value)

        guard count > 0 else {
            return .unavailable
        }

        for index in 0..<count {
            storage.append(input[index])
        }

        return .bytes(
            try PositiveByteCount(count)
        )
    }

    func refill(
        into output: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        let remaining = storage.count - readIndex

        guard remaining > 0 else {
            return finished ? .end : .unavailable
        }

        let count = min(
            output.count,
            min(remaining, maximumRefill.value)
        )

        guard count > 0 else {
            return .unavailable
        }

        for index in 0..<count {
            output[index] = storage[readIndex + index]
        }

        readIndex += count

        return .bytes(
            try PositiveByteCount(count)
        )
    }

    func finishInput() {
        finished = true
    }
}

private struct OverreportingSource: SourceBackend {
    mutating func refill(
        into bytes: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        .bytes(
            try PositiveByteCount(bytes.count + 1)
        )
    }
}

private struct OverreportingDestination: DestinationBackend {
    mutating func drain(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        .bytes(
            try PositiveByteCount(bytes.count + 1)
        )
    }
}
