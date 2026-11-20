#if canImport(Darwin)
import Darwin
import Foundation
import IO

/// Scanner / fingerprint probes: audit findings #8b, #9, line fingerprint.
enum HZScanProbes {
    static var probes: [HazardProbe] {
        [
            .init(
                "scanner-kernel-negative-index",
                finding: "#8b",
                onSignal: { signal in
                    .present("malformed kernel index trapped the process (\(HZ.signalName(signal))) instead of being rejected")
                },
                body: { try malformedKernel(HZNegativeIndexKernel.self, label: "index -1") }
            ),
            .init(
                "scanner-kernel-past-end-index",
                finding: "#8b",
                onSignal: { signal in
                    .present("malformed kernel index trapped the process (\(HZ.signalName(signal))) instead of being rejected")
                },
                body: { try malformedKernel(HZPastEndIndexKernel.self, label: "index count+16") }
            ),
            .init(
                "scanner-kernel-backward-index",
                finding: "#8b",
                onSignal: { signal in
                    .present("backward kernel index trapped the process (\(HZ.signalName(signal))) instead of being rejected")
                },
                body: { try malformedKernel(HZBackwardIndexKernel.self, label: "indices 5 then 2") }
            ),
            .init(
                "scanner-throw-progress",
                finding: "#9",
                body: { try scannerThrowProgress() }
            ),
            .init(
                "line-fingerprint-structure",
                finding: "fp",
                body: { try lineFingerprintStructure() }
            ),
        ]
    }

    /// The callback records only counts and ranges; it never dereferences the
    /// fragment pointer.
    static func malformedKernel<Kernel: ByteMatchKernel>(
        _ kernel: Kernel.Type,
        label: String
    ) throws -> HazardOutcome {
        let input = Array("alpha\nbeta\ngamma\n".utf8)
        var scanner = ByteLineScanner(
            source: Source(
                MemorySource(bytes: input),
                bufferCapacity: try BufferCapacity(64)
            )
        )
        var fragments: [(count: Int, range: Range<UInt64>)] = []
        let thrown: String

        HZ.step("\(label): scanning with malformed kernel")
        do {
            let result = try scanner.scan(using: kernel) { fragment in
                fragments.append((fragment.bytes.byteCount, fragment.byteRange))
                return .continue
            }
            thrown = "no error (result \(result))"
        } catch {
            thrown = "threw \(error)"
        }

        let limit = UInt64(input.count)
        let invalid = fragments.filter {
            $0.count < 0
                || $0.count > input.count
                || $0.range.upperBound > limit
        }

        if !invalid.isEmpty {
            let described = invalid
                .map { "count \($0.count) range \($0.range)" }
                .joined(separator: ", ")
            return .present(
                "\(label): callback received out-of-bounds fragment(s) [\(described)] before any validation; afterwards \(thrown)"
            )
        }

        if thrown.contains("byte_match_index_out_of_range") {
            return .absent(
                "\(label): malformed index rejected before pointer arithmetic after \(fragments.count) valid fragment(s) (\(thrown))"
            )
        }

        return .inconclusive("\(label): \(fragments.count) fragment(s), \(thrown)")
    }

    /// Line 1 returns normally, line 2 throws. The resumed scan tells us
    /// whether successfully returned fragments are replayed.
    static func scannerThrowProgress() throws -> HazardOutcome {
        let input = Array("one\ntwo\nthree\n".utf8)
        var scanner = ByteLineScanner(
            source: Source(
                MemorySource(bytes: input),
                bufferCapacity: try BufferCapacity(64)
            )
        )
        var firstPass: [String] = []

        HZ.step("first pass throws on line 2")
        do {
            _ = try scanner.scan { fragment in
                if fragment.lineNumber == 2 {
                    throw TestFailure(message: "scripted callback failure on line 2")
                }

                firstPass.append(fragment.bytes.withUnsafeBytes { String(decoding: $0, as: UTF8.self) })
                return .continue
            }
            return .inconclusive("callback failure did not propagate out of scan")
        } catch {}

        var secondPass: [String] = []

        HZ.step("resumed scan")
        while true {
            let result = try scanner.scan { fragment in
                secondPass.append(fragment.bytes.withUnsafeBytes { String(decoding: $0, as: UTF8.self) })
                return .continue
            }

            if result != .stopped {
                break
            }
        }

        let detail = "first pass delivered \(firstPass) then threw on line 2; resumed scan delivered \(secondPass)"

        if secondPass.first == "one" {
            return .present("successfully returned fragment was replayed — \(detail)")
        }

        if secondPass.first == "two" {
            return .absent(detail)
        }

        return .inconclusive(detail)
    }

    static func lineFingerprintStructure() throws -> HazardOutcome {
        let pairs: [([String], [String])] = [
            (["a\nb"], ["a", "b"]),
            (["a", ""], ["a\n"]),
        ]
        var collisions: [String] = []

        for (lhs, rhs) in pairs {
            let left: ContentFingerprint? = ContentFingerprint.fingerprint(for: lhs)
            let right: ContentFingerprint? = ContentFingerprint.fingerprint(for: rhs)

            if left == right {
                collisions.append("\(lhs.debugDescription) ≡ \(rhs.debugDescription)")
            }
        }

        if collisions.isEmpty {
            return .absent("structurally different line arrays fingerprint differently")
        }

        return .present(
            "structurally different line arrays fingerprint identically: \(collisions.joined(separator: "; "))"
        )
    }
}

enum HZNegativeIndexKernel: ByteMatchKernel {
    static func walk(
        _ bytes: RawSpan,
        needle: UInt8,
        from start: Int,
        _ body: (Int) throws -> ByteMatchDirective
    ) rethrows -> ByteMatchWalkResult {
        _ = try body(-1)
        return .complete
    }
}

enum HZPastEndIndexKernel: ByteMatchKernel {
    static func walk(
        _ bytes: RawSpan,
        needle: UInt8,
        from start: Int,
        _ body: (Int) throws -> ByteMatchDirective
    ) rethrows -> ByteMatchWalkResult {
        _ = try body(bytes.byteCount + 16)
        return .complete
    }
}

enum HZBackwardIndexKernel: ByteMatchKernel {
    static func walk(
        _ bytes: RawSpan,
        needle: UInt8,
        from start: Int,
        _ body: (Int) throws -> ByteMatchDirective
    ) rethrows -> ByteMatchWalkResult {
        guard bytes.byteCount > 6 else {
            return .complete
        }

        if try body(5) == .stop {
            return .stopped(at: 5)
        }

        _ = try body(2)
        return .complete
    }
}

#endif
