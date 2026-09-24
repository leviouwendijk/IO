/// Minimal ring-storage surface required by the Destination state machine.
///
/// The protocol is nonescapable-capable so the same algorithm can operate over
/// both ordinary owned `StreamRingBuffer` storage and lifetime-bound
/// `BorrowedStreamRingBuffer` storage.
package protocol DestinationRingStorage: ~Copyable, ~Escapable {
    var capacity: Int { get }
    var readableCount: Int { get }
    var writableCount: Int { get }
    var isEmpty: Bool { get }

    func withReadableRegions<Result>(
        _ body: (
            UnsafeRawBufferPointer,
            UnsafeRawBufferPointer
        ) throws -> Result
    ) rethrows -> Result

    @_lifetime(self: copy self)
    mutating func consume(
        _ count: Int
    )

    @_lifetime(self: copy self)
    mutating func append(
        _ byte: UInt8
    ) -> Bool

    @_lifetime(self: copy self)
    mutating func append(
        _ bytes: UnsafeRawBufferPointer
    ) -> Int
}

extension StreamRingBuffer: DestinationRingStorage {}
extension BorrowedStreamRingBuffer: DestinationRingStorage {}
