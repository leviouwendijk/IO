#if canImport(Darwin)
import Darwin
import Foundation
import IO

/// Stream-layer probes: audit findings #1, #2, #3b, #7a, #10.
enum HZStreamProbes {
    static var probes: [HazardProbe] {
        [
            .init(
                "bounded-stream-wrapped-ring",
                finding: "#1",
                body: { try boundedStreamWrappedRing() }
            ),
            .init(
                "socket-peer-close-vector-write",
                finding: "#2",
                onSignal: { sigpipeInterpretation($0) },
                body: { try socketPeerCloseVectorWrite() }
            ),
            .init(
                "socket-peer-close-scalar-send",
                finding: "#2",
                onSignal: { sigpipeInterpretation($0) },
                body: { try socketPeerCloseScalarSend() }
            ),
            .init(
                "socket-peer-close-after-adopt",
                finding: "#2",
                onSignal: { sigpipeInterpretation($0) },
                body: { try socketPeerCloseAfterAdopt() }
            ),
            .init(
                "pipe-destination-peer-close",
                finding: "#2",
                onSignal: { sigpipeInterpretation($0) },
                body: { try pipeDestinationPeerClose() }
            ),
            .init(
                "socket-after-close-fd-reuse",
                finding: "#3b",
                body: { try socketAfterCloseFdReuse() }
            ),
            .init(
                "socket-blocking-adopt-refused",
                finding: "sk",
                body: { try socketBlockingAdoptRefused() }
            ),
            .init(
                "destination-progress-before-error",
                finding: "#7a",
                body: { try destinationProgressBeforeError() }
            ),
            .init(
                "async-destination-progress-before-error",
                finding: "#7a",
                body: { try await asyncDestinationProgressBeforeError() }
            ),
            .init(
                "darwin-large-direct-write",
                finding: "#10",
                timeoutSeconds: 30,
                body: { try darwinLargeDirectWrite() }
            ),
        ]
    }

    static func sigpipeInterpretation(
        _ signal: Int32
    ) -> HazardOutcome {
        if signal == SIGPIPE {
            return .present("process was killed by SIGPIPE instead of observing EPIPE")
        }

        return .inconclusive("child terminated by \(HZ.signalName(signal))")
    }

    /// Capacity 8 → fill 8 → consume 6 → requestMore appends 6 at index 0.
    /// The readable window is then [6,7 | 8...13] across two physical regions.
    static func boundedStreamWrappedRing() throws -> HazardOutcome {
        let input = (0..<20).map { UInt8($0) }
        var source = Source(
            MemorySource(bytes: input),
            bufferCapacity: try BufferCapacity(8)
        )

        HZ.step("prepare initial 8 bytes")
        guard try source.prepare() == .bytes else {
            return .inconclusive("initial prepare did not produce bytes")
        }

        try source.consume(6)

        HZ.step("requestMore behind the unread suffix")
        guard try source.requestMore() == .bytes else {
            return .inconclusive("requestMore did not append bytes")
        }

        let (firstCount, logical) = source.withUnsafeReadableRegions { first, second in
            (first.count, Array(first) + Array(second))
        }

        guard firstCount == 2,
              logical == Array(input[6..<14])
        else {
            return .inconclusive(
                "fixture did not wrap as designed: first region \(firstCount), logical \(logical)"
            )
        }

        var destination = Destination(
            MemoryDestination(),
            bufferCapacity: try BufferCapacity(64)
        )

        HZ.step("bounded stream over wrapped ring")
        let result = try source.stream(
            to: &destination,
            maximumCount: 100
        )
        _ = try destination.flush()

        let captured = destination.inspectBackend().capturedBytes ?? []
        let expected = Array(input[6...])

        if captured == expected {
            return .absent("bounded stream delivered the logical sequence 6...19 (\(result))")
        }

        return .present(
            "expected \(expected), destination received \(captured) (\(result)); bytes 2..<8 were read past the first physical region"
        )
    }

    static func socketPeerCloseVectorWrite() throws -> HazardOutcome {
        let (local, peer) = try HZ.socketPair()
        HZ.close(peer)

        let backend = try NonblockingSocketBackend(
            descriptor: local,
            ownsDescriptor: true
        )
        var destination = Destination(
            backend,
            bufferCapacity: try BufferCapacity(4)
        )

        HZ.step("Destination direct/vector write to a socket whose peer is closed")
        do {
            let result = try destination.write(
                [UInt8](repeating: 7, count: 16)
            )
            return .inconclusive("write to a closed peer returned \(result) without an error")
        } catch let error as POSIXIOError {
            return .absent("vector path surfaced \(error) and the process survived")
        }
    }

    /// A blocking socket adopted with `setNonblocking: false` would let a pending
    /// `recv` hold the lifecycle lock and stall `send` and `close()` behind it.
    static func socketBlockingAdoptRefused() throws -> HazardOutcome {
        let (local, peer) = try HZ.socketPair()
        defer {
            HZ.close(local)
            HZ.close(peer)
        }

        HZ.step("adopt a blocking socket with setNonblocking: false")
        let refusal: POSIXIOError
        do {
            _ = try NonblockingSocketBackend(
                descriptor: local,
                setNonblocking: false,
                ownsDescriptor: false
            )
            return .present("blocking socket was adopted; a pending recv would hold the lifecycle lock and stall send and close")
        } catch let error as POSIXIOError {
            refusal = error
        }

        guard Darwin.fcntl(local, F_GETFD) != -1 else {
            return .present("blocking socket was refused (\(refusal)) but the caller-owned descriptor was closed")
        }

        guard Darwin.fcntl(local, F_GETFL) & O_NONBLOCK == 0 else {
            return .present("blocking socket was refused (\(refusal)) but its flags were changed")
        }

        HZ.step("adopt an already-nonblocking socket with setNonblocking: false")
        let flags = Darwin.fcntl(peer, F_GETFL)
        guard flags >= 0, Darwin.fcntl(peer, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return .inconclusive("could not make the peer socket nonblocking (errno \(errno))")
        }

        let adopted = try NonblockingSocketBackend(
            descriptor: peer,
            setNonblocking: false,
            ownsDescriptor: false
        )
        let readinessText = adopted.readinessDescriptor.map { "\($0)" } ?? "nil"

        return .absent("blocking socket refused with \(refusal), descriptor left open and unchanged; nonblocking socket adopted (readinessDescriptor: \(readinessText))")
    }

    static func socketPeerCloseScalarSend() throws -> HazardOutcome {
        let (local, peer) = try HZ.socketPair()
        HZ.close(peer)

        let backend = try NonblockingSocketBackend(
            descriptor: local,
            ownsDescriptor: true
        )
        let payload = [UInt8](repeating: 7, count: 16)

        HZ.step("scalar backend drain to a socket whose peer is closed")
        do {
            let result = try payload.withUnsafeBytes {
                try backend.drain($0)
            }
            return .inconclusive("scalar drain to a closed peer returned \(result)")
        } catch let error as POSIXIOError {
            return .absent("scalar path surfaced \(error) and the process survived")
        }
    }

    /// Realistic ordering: adopt a live socket, lose the peer, then write. The other
    /// two socket probes adopt an already shut-down socket, which exercises the
    /// Darwin `SO_NOSIGPIPE`-refused path instead.
    static func socketPeerCloseAfterAdopt() throws -> HazardOutcome {
        let (local, peer) = try HZ.socketPair()

        let backend = try NonblockingSocketBackend(
            descriptor: local,
            ownsDescriptor: true
        )
        var destination = Destination(
            backend,
            bufferCapacity: try BufferCapacity(4)
        )

        HZ.close(peer)

        HZ.step("Destination write after the adopted socket's peer closed")
        do {
            let result = try destination.write(
                [UInt8](repeating: 7, count: 16)
            )
            return .inconclusive("write after peer close returned \(result) without an error")
        } catch let error as POSIXIOError {
            return .absent("write surfaced \(error) and the process survived")
        }
    }

    /// Opens `/dev/fd/N` (a dup on Darwin) so `SystemFileDestination` owns a
    /// pipe write end, then closes every read end.
    static func pipeDestinationPeerClose() throws -> HazardOutcome {
        let (readEnd, writeEnd) = try HZ.pipePair()
        var destination = try Destination(
            SystemFileDestination(
                path: "/dev/fd/\(writeEnd)",
                mode: .append
            ),
            bufferCapacity: BufferCapacity(4)
        )
        HZ.close(readEnd)
        HZ.close(writeEnd)

        HZ.step("SystemFileDestination write to a pipe without readers")
        do {
            let result = try destination.write(
                [UInt8](repeating: 7, count: 16)
            )
            return .inconclusive("write to a reader-less pipe returned \(result)")
        } catch SystemFileDestinationError.write(_, let code) {
            return .absent("pipe write surfaced errno \(code) and the process survived")
        }
    }

    /// Closes the backend, reuses its descriptor number for a different
    /// socket via dup2, then drives refill/drain on the closed backend.
    static func socketAfterCloseFdReuse() throws -> HazardOutcome {
        let (original, originalPeer) = try HZ.socketPair()
        defer { HZ.close(originalPeer) }

        let backend = try NonblockingSocketBackend(
            descriptor: original,
            ownsDescriptor: true
        )

        HZ.step("close backend")
        try backend.close()
        let readinessAfterClose = backend.readinessDescriptor

        // The kernel hands out the lowest free descriptor number, so the new
        // socketpair frequently reuses `original` by itself. Only dup2 when it
        // did not; closing `replacement` in the reuse case would close the very
        // socket under test.
        let (replacement, replacementPeer) = try HZ.socketPair()
        defer { HZ.close(replacementPeer) }

        let reuse: String

        if replacement == original {
            reuse = "kernel reused descriptor \(original) naturally"
        } else {
            guard Darwin.dup2(replacement, original) == original else {
                HZ.close(replacement)
                return .inconclusive("dup2 onto the closed descriptor number failed with errno \(errno)")
            }

            HZ.close(replacement)
            reuse = "descriptor \(original) reused via dup2"
        }

        defer { HZ.close(original) }

        let marker: [UInt8] = [0x5A, 0x5B]
        let seeded = marker.withUnsafeBytes {
            Darwin.send(replacementPeer, $0.baseAddress, $0.count, 0)
        }

        guard seeded == marker.count else {
            return .inconclusive("could not seed the replacement socket")
        }

        HZ.step("refill on closed backend")
        var readTouched = false
        var buffer = [UInt8](repeating: 0, count: 8)
        let readObservation: String

        do {
            let refill = try buffer.withUnsafeMutableBytes {
                try backend.refill(into: $0)
            }

            if case .bytes(let count) = refill,
               Array(buffer.prefix(count.value)) == marker
            {
                readTouched = true
            }

            readObservation = "refill returned \(refill)"
        } catch {
            readObservation = "refill threw \(error)"
        }

        HZ.step("drain on closed backend")
        let payload: [UInt8] = [0xA5]
        let writeObservation: String

        do {
            let drain = try payload.withUnsafeBytes {
                try backend.drain($0)
            }
            writeObservation = "drain returned \(drain)"
        } catch {
            writeObservation = "drain threw \(error)"
        }

        var received = [UInt8](repeating: 0, count: 4)
        let receivedCount = received.withUnsafeMutableBytes {
            Darwin.recv(replacementPeer, $0.baseAddress, $0.count, MSG_DONTWAIT)
        }
        let writeTouched = receivedCount > 0 && received[0] == 0xA5

        let readiness = readinessAfterClose.map { String($0) } ?? "nil"
        let summary = "\(reuse); readinessDescriptor after close: \(readiness); \(readObservation); \(writeObservation)"

        if readTouched || writeTouched {
            return .present(
                "closed backend reached the replacement socket (read: \(readTouched), write: \(writeTouched)); \(summary)"
            )
        }

        return .absent("closed backend never touched the replacement socket; \(summary)")
    }

    /// First drain accepts 3 bytes, second drain throws. Capacity 4 forces two
    /// direct-bypass drains inside one `write` call.
    static func destinationProgressBeforeError() throws -> HazardOutcome {
        var destination = Destination(
            HZThrowOnSecondDrainBackend(acceptPerDrain: 3),
            bufferCapacity: try BufferCapacity(4)
        )
        let payload = (0..<10).map { UInt8($0) }

        HZ.step("write 10 bytes: accept 3, then throw")
        do {
            let result = try destination.write(payload)
            let captured = destination.inspectBackend().capturedBytes ?? []

            if case .partial(let accepted) = result,
               accepted.value == captured.count
            {
                return .absent("write reported .partial(\(accepted.value)) matching the backend-accepted prefix")
            }

            return .inconclusive("write returned \(result); backend captured \(captured.count) bytes")
        } catch {
            let captured = destination.inspectBackend().capturedBytes ?? []

            if !captured.isEmpty {
                return .present(
                    "write threw '\(error)' after the backend had already accepted \(captured.count) caller bytes; the accepted prefix is not reported"
                )
            }

            return .inconclusive("write threw \(error) with nothing accepted")
        }
    }

    /// Async form of #7a. The backend accepts 3 bytes, then throws, and reports a
    /// writable readiness descriptor, so the async loop waits and writes again. The
    /// accepted prefix must be reported, and the failure must surface on the next call.
    static func asyncDestinationProgressBeforeError() async throws -> HazardOutcome {
        let (readEnd, writeEnd) = try HZ.pipePair()
        defer {
            HZ.close(readEnd)
            HZ.close(writeEnd)
        }

        var destination = Destination(
            HZThrowOnSecondDrainBackend(
                acceptPerDrain: 3,
                readinessDescriptor: writeEnd
            ),
            bufferCapacity: try BufferCapacity(4)
        )
        let payload = (0..<10).map { UInt8($0) }

        HZ.step("async write of 10 bytes: accept 3, then throw; readiness is writable")
        let result: DestinationWrite

        do {
            result = try await destination.write(payload, io: IO.blocking)
        } catch {
            let captured = destination.inspectBackend().capturedBytes ?? []

            if !captured.isEmpty {
                return .present(
                    "async write threw '\(error)' after the backend had already accepted \(captured.count) caller bytes; the accepted prefix is not reported"
                )
            }

            return .inconclusive("async write threw \(error) with nothing accepted")
        }

        let captured = destination.inspectBackend().capturedBytes ?? []

        guard case .partial(let accepted) = result,
              accepted.value == captured.count
        else {
            return .inconclusive("async write returned \(result); backend captured \(captured.count) bytes")
        }

        HZ.step("next write surfaces the deferred failure")

        do {
            _ = try destination.write([10])
        } catch {
            return .absent(
                "async write reported .partial(\(accepted.value)) matching the backend-accepted prefix; the deferred failure surfaced on the next write"
            )
        }

        return .present(
            "async write reported .partial(\(accepted.value)) but the backend failure was lost"
        )
    }

    /// Darwin `write(2)` rejects counts above INT_MAX. `/dev/null` never reads
    /// the pages, so the 2 GiB allocation stays untouched.
    static func darwinLargeDirectWrite() throws -> HazardOutcome {
        let byteCount = Int(Int32.max) + 4096
        let storage = UnsafeMutableRawBufferPointer.allocate(
            byteCount: byteCount,
            alignment: 16
        )
        defer { storage.deallocate() }

        var destination = try Destination(
            SystemFileDestination(
                path: "/dev/null",
                mode: .append
            ),
            bufferCapacity: BufferCapacity(64)
        )

        HZ.step("direct write of \(byteCount) bytes to /dev/null")
        do {
            let result = try destination.write(
                UnsafeRawBufferPointer(storage)
            )
            return .absent("a single >INT_MAX direct write was accepted: \(result)")
        } catch SystemFileDestinationError.write(_, let code) {
            if code == EINVAL {
                return .present("kernel rejected the >INT_MAX direct write with EINVAL; no chunking at the syscall boundary")
            }

            return .inconclusive("large write failed with errno \(code)")
        }
    }
}

/// Destination backend whose first drain accepts a prefix and whose second
/// drain throws.
struct HZThrowOnSecondDrainBackend: DestinationBackend, ~Copyable {
    private var captured: [UInt8]
    private var drainCount: Int
    private let acceptPerDrain: Int
    private let readiness: Int32?

    init(
        acceptPerDrain: Int,
        readinessDescriptor: Int32? = nil
    ) {
        self.captured = []
        self.drainCount = 0
        self.acceptPerDrain = acceptPerDrain
        self.readiness = readinessDescriptor
    }

    var readinessDescriptor: Int32? {
        readiness
    }

    mutating func drain(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        drainCount += 1

        guard drainCount == 1 else {
            throw TestFailure(message: "scripted backend failure on drain \(drainCount)")
        }

        let count = min(acceptPerDrain, bytes.count)
        captured.append(contentsOf: bytes.prefix(count))
        return .bytes(try PositiveByteCount(count))
    }

    mutating func inspect() -> DestinationBackendInspection {
        .init(capturedBytes: captured)
    }
}

#endif
