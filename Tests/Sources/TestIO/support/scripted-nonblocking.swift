import IO

/// Deterministic Source backend for partial-progress/backpressure tests.
public struct ScriptedSourceBackend: SourceBackend, ~Copyable {
    public enum Step: Sendable, Equatable {
        case bytes([UInt8])
        case unavailable
        case retry
        case end
    }

    private var steps: [Step]
    private var index: Int
    private var byteOffset: Int

    public init(steps: [Step]) {
        self.steps = steps
        self.index = 0
        self.byteOffset = 0
    }

    public mutating func refill(
        into output: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        guard index < steps.count else { return .end }

        switch steps[index] {
        case .unavailable:
            index += 1
            return .unavailable

        case .retry:
            index += 1
            return .retry

        case .end:
            index += 1
            return .end

        case .bytes(let bytes):
            let remaining = bytes.count - byteOffset
            let count = min(output.count, remaining)
            guard count > 0 else {
                index += 1
                byteOffset = 0
                return try refill(into: output)
            }

            if let destination = output.baseAddress {
                bytes.withUnsafeBytes { source in
                    if let base = source.baseAddress {
                        destination.copyMemory(
                            from: base.advanced(by: byteOffset),
                            byteCount: count
                        )
                    }
                }
            }

            byteOffset += count
            if byteOffset == bytes.count {
                index += 1
                byteOffset = 0
            }

            return .bytes(try PositiveByteCount(count))
        }
    }
}

/// Deterministic Destination backend that can accept short prefixes or inject
/// backpressure between successful drains.
public struct ScriptedDestinationBackend: DestinationBackend, ~Copyable {
    public enum Step: Sendable, Equatable {
        case accept(Int)
        case unavailable
    }

    private var steps: [Step]
    private var index: Int
    private var bytes: [UInt8]

    public init(steps: [Step]) {
        self.steps = steps
        self.index = 0
        self.bytes = []
    }

    public mutating func drain(
        _ input: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        guard !input.isEmpty else { return .unavailable }

        let step: Step = index < steps.count
            ? steps[index]
            : .accept(input.count)
        index += 1

        switch step {
        case .unavailable:
            return .unavailable

        case .accept(let maximum):
            let count = min(input.count, maximum)
            guard count > 0 else { return .unavailable }
            bytes.reserveCapacity(bytes.count + count)
            for offset in 0..<count {
                bytes.append(input[offset])
            }
            return .bytes(try PositiveByteCount(count))
        }
    }

    public mutating func inspect() -> DestinationBackendInspection {
        .init(capturedBytes: bytes)
    }
}
