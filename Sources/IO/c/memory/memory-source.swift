/// Deterministic uniquely-owned in-memory `SourceBackend`.
public struct MemorySource: SourceBackend, ~Copyable {
    public let bytes: [UInt8]
    public let maximumChunkSize: PositiveByteCount?

    private var offset: Int

    public init(
        bytes: [UInt8],
        maximumChunkSize: PositiveByteCount? = nil
    ) {
        self.bytes = bytes
        self.maximumChunkSize = maximumChunkSize
        self.offset = 0
    }

    public mutating func refill(
        into output: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        guard offset < bytes.count else {
            return .end
        }

        let remaining = bytes.count - offset
        let backendLimit = maximumChunkSize?.value ?? Int.max
        let count = min(
            output.count,
            min(
                remaining,
                backendLimit
            )
        )

        guard count > 0 else {
            return .unavailable
        }

        for index in 0..<count {
            output[index] = bytes[offset + index]
        }

        offset += count

        let progress = PositiveByteCount.knownPositive(
            count
        )

        if offset == bytes.count {
            return .final_bytes(
                progress
            )
        }

        return .bytes(
            progress
        )
    }

    public mutating func refill(
        first: UnsafeMutableRawBufferPointer,
        second: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        guard offset < bytes.count else {
            return .end
        }

        let remaining = bytes.count - offset
        let backendLimit = maximumChunkSize?.value ?? Int.max
        let count = min(
            first.count + second.count,
            min(remaining, backendLimit)
        )

        guard count > 0 else {
            return .unavailable
        }

        var copied = 0

        if !first.isEmpty {
            let amount = min(first.count, count)
            for index in 0..<amount {
                first[index] = bytes[offset + copied + index]
            }
            copied += amount
        }

        if copied < count && !second.isEmpty {
            let amount = min(second.count, count - copied)
            for index in 0..<amount {
                second[index] = bytes[offset + copied + index]
            }
            copied += amount
        }

        offset += copied
        let progress = PositiveByteCount.knownPositive(copied)

        if offset == bytes.count {
            return .final_bytes(progress)
        }

        return .bytes(progress)
    }

}
