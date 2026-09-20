/// Fixed-capacity ring storage for long-lived streaming endpoints.
///
/// Readable and writable logical ranges may occupy at most two physical regions. Cursor
/// movement never relocates retained payload bytes.
package struct StreamRingBuffer {
    private var storage: [UInt8]
    private var readIndex: Int
    private var readableByteCount: Int

    package init(capacity: BufferCapacity) {
        self.storage = Array(repeating: 0, count: capacity.value)
        self.readIndex = 0
        self.readableByteCount = 0
    }

    package var capacity: Int { storage.count }
    package var readableCount: Int { readableByteCount }
    package var writableCount: Int { capacity - readableByteCount }
    package var isEmpty: Bool { readableByteCount == 0 }
    package var isFull: Bool { readableByteCount == capacity }

    private var writeIndex: Int {
        (readIndex + readableByteCount) % capacity
    }

    /// Borrows the readable ring as at most two physical spans, in logical order.
    package func withReadableRegions<Result>(
        _ body: (UnsafeRawBufferPointer, UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        let firstCount = min(readableByteCount, capacity - readIndex)
        let secondCount = readableByteCount - firstCount

        return try storage.withUnsafeBytes { raw in
            let first = UnsafeRawBufferPointer(
                start: raw.baseAddress.map { $0.advanced(by: readIndex) },
                count: firstCount
            )
            let second = UnsafeRawBufferPointer(
                start: raw.baseAddress,
                count: secondCount
            )
            return try body(first, second)
        }
    }

    /// Borrows the writable ring as at most two physical spans, in logical order.
    /// Cursor state advances only after `didWrite(_:)`.
    package mutating func withWritableRegions<Result>(
        _ body: (UnsafeMutableRawBufferPointer, UnsafeMutableRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        let write = writeIndex
        let available = writableCount
        let firstCount = min(available, capacity - write)
        let secondCount = available - firstCount

        return try storage.withUnsafeMutableBytes { raw in
            let first = UnsafeMutableRawBufferPointer(
                start: raw.baseAddress.map { $0.advanced(by: write) },
                count: firstCount
            )
            let second = UnsafeMutableRawBufferPointer(
                start: raw.baseAddress,
                count: secondCount
            )
            return try body(first, second)
        }
    }

    package mutating func didWrite(_ count: Int) {
        precondition(count >= 0 && count <= writableCount)
        readableByteCount += count
    }

    package mutating func consume(_ count: Int) {
        precondition(count >= 0 && count <= readableByteCount)
        readIndex = (readIndex + count) % capacity
        readableByteCount -= count
        if readableByteCount == 0 {
            readIndex = 0
        }
    }



    /// Appends one byte without compacting retained data.
    package mutating func append(_ byte: UInt8) -> Bool {
        guard writableCount > 0 else { return false }

        let index = writeIndex
        storage[index] = byte
        readableByteCount += 1
        return true
    }

    package mutating func append(_ bytes: UnsafeRawBufferPointer) -> Int {
        let accepted = min(bytes.count, writableCount)
        guard accepted > 0 else { return 0 }

        var copied = 0
        withWritableRegions { first, second in
            if !first.isEmpty, let destination = first.baseAddress, let source = bytes.baseAddress {
                let count = min(first.count, accepted)
                destination.copyMemory(from: source, byteCount: count)
                copied += count
            }
            if copied < accepted,
               !second.isEmpty,
               let destination = second.baseAddress,
               let source = bytes.baseAddress
            {
                let count = accepted - copied
                destination.copyMemory(from: source.advanced(by: copied), byteCount: count)
                copied += count
            }
        }
        didWrite(copied)
        return copied
    }
}
