/// Storage-independent cursor state for a fixed-capacity byte ring.
///
/// This type owns no byte storage. It only tracks the logical readable window
/// and computes the at-most-two physical ranges that represent readable and
/// writable regions in caller-supplied contiguous storage.
@_spi(Testing) public struct StreamRingState: Sendable {
    private let capacityValue: Int
    private var readIndex: Int
    private var readableByteCount: Int

    @_spi(Testing) public init(capacity: Int) {
        precondition(capacity > 0, "ring capacity must be greater than zero")
        self.capacityValue = capacity
        self.readIndex = 0
        self.readableByteCount = 0
    }

    @_spi(Testing) public var capacity: Int { capacityValue }
    @_spi(Testing) public var readableCount: Int { readableByteCount }
    @_spi(Testing) public var writableCount: Int { capacityValue - readableByteCount }
    @_spi(Testing) public var isEmpty: Bool { readableByteCount == 0 }
    @_spi(Testing) public var isFull: Bool { readableByteCount == capacityValue }

    @_spi(Testing) public var writeIndex: Int {
        (readIndex + readableByteCount) % capacityValue
    }

    @_spi(Testing) public func readableRanges() -> (
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

    @_spi(Testing) public func writableRanges() -> (
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

    @_spi(Testing) public mutating func didWrite(_ count: Int) {
        precondition(count >= 0 && count <= writableCount)
        readableByteCount += count
    }

    @_spi(Testing) public mutating func consume(_ count: Int) {
        precondition(count >= 0 && count <= readableByteCount)
        readIndex = (readIndex + count) % capacityValue
        readableByteCount -= count

        if readableByteCount == 0 {
            readIndex = 0
        }
    }
}
