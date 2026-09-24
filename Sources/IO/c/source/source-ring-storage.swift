/// Minimal ring-storage surface required by the Source state machine.
///
/// The protocol is nonescapable-capable so the same algorithm can operate over
/// both ordinary owned `StreamRingBuffer` storage and lifetime-bound
/// `BorrowedStreamRingBuffer` storage.
package protocol SourceRingStorage: ~Copyable, ~Escapable {
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
    mutating func withWritableRegions<Result>(
        _ body: (
            UnsafeMutableRawBufferPointer,
            UnsafeMutableRawBufferPointer
        ) throws -> Result
    ) rethrows -> Result

    @_lifetime(self: copy self)
    mutating func didWrite(
        _ count: Int
    )

    @_lifetime(self: copy self)
    mutating func consume(
        _ count: Int
    )
}

extension StreamRingBuffer: SourceRingStorage {}
extension BorrowedStreamRingBuffer: SourceRingStorage {}
