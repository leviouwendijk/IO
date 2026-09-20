/// Deterministic uniquely-owned in-memory `DestinationBackend`.
public struct MemoryDestination: DestinationBackend, ~Copyable {
    public let maximumChunkSize: PositiveByteCount?

    private var bytes: [UInt8]

    public init(
        maximumChunkSize: PositiveByteCount? = nil
    ) {
        self.maximumChunkSize = maximumChunkSize
        self.bytes = []
    }

    public mutating func drain(
        _ input: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        let count = min(
            input.count,
            maximumChunkSize?.value ?? Int.max
        )

        guard count > 0 else {
            return .unavailable
        }

        bytes.reserveCapacity(
            bytes.count + count
        )

        for index in 0..<count {
            bytes.append(
                input[index]
            )
        }

        return .bytes(
            .knownPositive(
                count
            )
        )
    }


    public mutating func drain(
        first: UnsafeRawBufferPointer,
        second: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        let count = min(
            first.count + second.count,
            maximumChunkSize?.value ?? Int.max
        )

        guard count > 0 else {
            return .unavailable
        }

        bytes.reserveCapacity(bytes.count + count)

        var copied = 0
        if !first.isEmpty {
            let amount = min(first.count, count)
            for index in 0..<amount {
                bytes.append(first[index])
            }
            copied += amount
        }

        if copied < count && !second.isEmpty {
            let amount = min(second.count, count - copied)
            for index in 0..<amount {
                bytes.append(second[index])
            }
            copied += amount
        }

        return .bytes(.knownPositive(copied))
    }

    public mutating func inspect() -> DestinationBackendInspection {
        .init(
            capturedBytes: bytes
        )
    }
}
