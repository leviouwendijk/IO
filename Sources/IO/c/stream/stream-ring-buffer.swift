/// Fixed-capacity owning ring storage for long-lived streaming endpoints.
///
/// Ring cursor mechanics live in `StreamRingState`; this wrapper supplies the
/// current owned `[UInt8]` storage. Readable and writable logical ranges may
/// occupy at most two physical regions. Cursor movement never relocates
/// retained payload bytes.
package struct StreamRingBuffer {
    private var storage: [UInt8]
    private var state: StreamRingState

    package init(capacity: BufferCapacity) {
        self.storage = Array(
            repeating: 0,
            count: capacity.value
        )
        self.state = StreamRingState(
            capacity: capacity.value
        )
    }

    package var capacity: Int { state.capacity }
    package var readableCount: Int { state.readableCount }
    package var writableCount: Int { state.writableCount }
    package var isEmpty: Bool { state.isEmpty }
    package var isFull: Bool { state.isFull }

    package func withReadableRegions<Result>(
        _ body: (
            UnsafeRawBufferPointer,
            UnsafeRawBufferPointer
        ) throws -> Result
    ) rethrows -> Result {
        let ranges = state.readableRanges()

        return try storage.withUnsafeBytes { raw in
            let first = UnsafeRawBufferPointer(
                start: raw.baseAddress.map {
                    $0.advanced(by: ranges.first.lowerBound)
                },
                count: ranges.first.count
            )
            let second = UnsafeRawBufferPointer(
                start: raw.baseAddress.map {
                    $0.advanced(by: ranges.second.lowerBound)
                },
                count: ranges.second.count
            )
            return try body(first, second)
        }
    }

    package mutating func withWritableRegions<Result>(
        _ body: (
            UnsafeMutableRawBufferPointer,
            UnsafeMutableRawBufferPointer
        ) throws -> Result
    ) rethrows -> Result {
        let ranges = state.writableRanges()

        return try storage.withUnsafeMutableBytes { raw in
            let first = UnsafeMutableRawBufferPointer(
                start: raw.baseAddress.map {
                    $0.advanced(by: ranges.first.lowerBound)
                },
                count: ranges.first.count
            )
            let second = UnsafeMutableRawBufferPointer(
                start: raw.baseAddress.map {
                    $0.advanced(by: ranges.second.lowerBound)
                },
                count: ranges.second.count
            )
            return try body(first, second)
        }
    }

    package mutating func didWrite(_ count: Int) {
        state.didWrite(count)
    }

    package mutating func consume(_ count: Int) {
        state.consume(count)
    }

    package mutating func append(_ byte: UInt8) -> Bool {
        guard state.writableCount > 0 else { return false }

        storage[state.writeIndex] = byte
        state.didWrite(1)
        return true
    }

    package mutating func append(
        _ bytes: UnsafeRawBufferPointer
    ) -> Int {
        let accepted = min(bytes.count, state.writableCount)
        guard accepted > 0 else { return 0 }

        var copied = 0

        withWritableRegions { first, second in
            if !first.isEmpty,
               let destination = first.baseAddress,
               let source = bytes.baseAddress
            {
                let count = min(first.count, accepted)
                destination.copyMemory(
                    from: source,
                    byteCount: count
                )
                copied += count
            }

            if copied < accepted,
               !second.isEmpty,
               let destination = second.baseAddress,
               let source = bytes.baseAddress
            {
                let count = accepted - copied
                destination.copyMemory(
                    from: source.advanced(by: copied),
                    byteCount: count
                )
                copied += count
            }
        }

        state.didWrite(copied)
        return copied
    }
}
