/// Storage-independent cursor state for a fixed-capacity byte ring.
///
/// This type owns no byte storage. It only tracks the logical readable window
/// and computes the at-most-two physical ranges that represent readable and
/// writable regions in caller-supplied contiguous storage.
package struct StreamRingState: Sendable {
    private let capacityValue: Int
    private var readIndex: Int
    private var readableByteCount: Int

    package init(capacity: Int) {
        precondition(capacity > 0, "ring capacity must be greater than zero")
        self.capacityValue = capacity
        self.readIndex = 0
        self.readableByteCount = 0
    }

    package var capacity: Int { capacityValue }
    package var readableCount: Int { readableByteCount }
    package var writableCount: Int { capacityValue - readableByteCount }
    package var isEmpty: Bool { readableByteCount == 0 }
    package var isFull: Bool { readableByteCount == capacityValue }

    package var writeIndex: Int {
        (readIndex + readableByteCount) % capacityValue
    }

    package func readableRanges() -> (
        first: Range<Int>,
        second: Range<Int>
    ) {
        let firstCount = min(readableByteCount, capacityValue - readIndex)
        let secondCount = readableByteCount - firstCount

        return (
            readIndex..<(readIndex + firstCount),
            0..<secondCount
        )
    }

    package func writableRanges() -> (
        first: Range<Int>,
        second: Range<Int>
    ) {
        let write = writeIndex
        let available = writableCount
        let firstCount = min(available, capacityValue - write)
        let secondCount = available - firstCount

        return (
            write..<(write + firstCount),
            0..<secondCount
        )
    }

    package mutating func didWrite(_ count: Int) {
        precondition(count >= 0 && count <= writableCount)
        readableByteCount += count
    }

    package mutating func consume(_ count: Int) {
        precondition(count >= 0 && count <= readableByteCount)
        readIndex = (readIndex + count) % capacityValue
        readableByteCount -= count

        if readableByteCount == 0 {
            readIndex = 0
        }
    }
}
