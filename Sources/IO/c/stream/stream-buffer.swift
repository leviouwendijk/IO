#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

package struct StreamBufferCompactionStatistics: Sendable, Equatable {
    package let callCount: UInt64
    package let movedByteCount: UInt64

    package init(
        callCount: UInt64,
        movedByteCount: UInt64
    ) {
        self.callCount = callCount
        self.movedByteCount = movedByteCount
    }
}

/// Shared contiguous staging storage used by both `Source` and `Destination`.
///
/// `StreamBuffer` is intentionally kept on the shared side of the backend boundary.
/// Cursor management, small copies, and tiny writes are universal mechanics that should
/// remain compiler-visible rather than being reimplemented behind every backend.
///
/// The current storage is `[UInt8]`, which is convenient for the experiment but not yet
/// a declaration that Array/COW storage is the final systems representation. We still
/// need to measure allocations, COW behavior, ARC traffic, and alternatives.
///
/// The valid readable region is:
///
///     storage[readIndex ..< writeIndex]
///
/// and the immediately writable region is:
///
///     storage[writeIndex ..< storage.count]
///
/// Consumed prefix space can be recovered by `compact()`.
package struct StreamBuffer {
    /// Owns the bytes backing the stream's staging area.
    ///
    /// Backend code only receives scoped raw-buffer borrows into this storage; it must
    /// not retain those pointers after the borrowing closure/backend call returns.
    private var storage: [UInt8]

    /// Index of the first byte that has not yet been consumed.
    private var readIndex: Int

    /// Index one past the last initialized/readable byte.
    private var writeIndex: Int

    /// Diagnostic counters for actual payload-moving compactions.
    private var compactionCallCount: UInt64
    private var compactedByteCount: UInt64

    /// Allocates an empty buffer with a validated nonzero capacity.
    package init(
        capacity: BufferCapacity
    ) {
        self.storage = Array(
            repeating: 0,
            count: capacity.value
        )
        self.readIndex = 0
        self.writeIndex = 0
        self.compactionCallCount = 0
        self.compactedByteCount = 0
    }

    package var compactionStatistics: StreamBufferCompactionStatistics {
        .init(
            callCount: compactionCallCount,
            movedByteCount: compactedByteCount
        )
    }

    /// Total storage capacity, independent of the current cursor positions.
    package var capacity: Int {
        storage.count
    }

    /// Number of bytes currently initialized and available to a consumer.
    package var readableCount: Int {
        writeIndex - readIndex
    }

    /// Number of bytes that can be appended contiguously without first compacting.
    ///
    /// This is deliberately not `capacity - readableCount`: consumed prefix space is not
    /// writable until `compact()` moves the unread tail back to the front.
    package var writableCount: Int {
        storage.count - writeIndex
    }

    /// Whether there are currently no unread bytes.
    package var isEmpty: Bool {
        readableCount == 0
    }

    /// Borrows the contiguous uninitialized tail into which a Source backend may write.
    ///
    /// The closure receives only `[writeIndex ..< capacity]`. Merely writing into the
    /// pointer does not advance stream state; the owner must subsequently call
    /// `didWrite(_:)` with the backend-reported progress.
    ///
    /// Keeping cursor advancement outside the backend is intentional: byte storage and
    /// cursor mechanics remain north of the dynamic dispatch boundary.
    package mutating func withWritableBytes<Result>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        let index = writeIndex
        let count = writableCount

        return try storage.withUnsafeMutableBytes { rawBuffer in
            let start = rawBuffer.baseAddress.map {
                $0.advanced(
                    by: index
                )
            }

            return try body(
                UnsafeMutableRawBufferPointer(
                    start: start,
                    count: count
                )
            )
        }
    }

    /// Borrows the currently readable contiguous bytes without copying them.
    ///
    /// The returned pointer is valid only for the duration of `body`. This scoped-borrow
    /// shape is important for parsers and codecs: they can inspect the Source's existing
    /// buffer directly instead of allocating/copying into another temporary buffer.
    package func withReadableBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        let index = readIndex
        let count = readableCount

        return try storage.withUnsafeBytes { rawBuffer in
            let start = rawBuffer.baseAddress.map {
                $0.advanced(
                    by: index
                )
            }

            return try body(
                UnsafeRawBufferPointer(
                    start: start,
                    count: count
                )
            )
        }
    }

    /// Advances the write cursor after external code has initialized bytes in the
    /// writable region.
    ///
    /// This is an internal trusted operation. Public/backend-facing bounds are checked
    /// before reaching it, so preconditions document invariants rather than recoverable
    /// input errors.
    package mutating func didWrite(
        _ count: Int
    ) {
        precondition(count >= 0)
        precondition(count <= writableCount)

        writeIndex += count
    }

    /// Advances the read cursor after bytes have been successfully consumed.
    ///
    /// Once the readable range becomes empty, both cursors reset to zero. That restores
    /// the entire allocation as immediately writable without performing a copy.
    package mutating func consume(
        _ count: Int
    ) {
        precondition(count >= 0)
        precondition(count <= readableCount)

        readIndex += count

        if readIndex == writeIndex {
            readIndex = 0
            writeIndex = 0
        }
    }

    /// Appends one byte to the shared buffer.
    ///
    /// This is the key tiny-write path for `Destination`: when space exists it is only a
    /// bounds decision, a store, and cursor movement, with no backend dispatch.
    ///
    /// If prefix space has been consumed and the tail is full, the method first compacts
    /// the unread bytes. It returns `false` only when the buffer remains genuinely full.
    package mutating func append(
        _ byte: UInt8
    ) -> Bool {
        if writableCount == 0 && readIndex > 0 {
            compact()
        }

        guard writableCount > 0 else {
            return false
        }

        storage[writeIndex] = byte
        writeIndex += 1

        return true
    }

    /// Copies as many bytes as currently fit into the Destination's staging buffer.
    ///
    /// The return value is the number accepted into this buffer, which may be less than
    /// `bytes.count`. This operation intentionally describes *local buffering* rather
    /// than endpoint progress.
    ///
    /// Large writes can bypass this copy entirely in `Destination.write(_:)` when the
    /// internal buffer is empty.
    package mutating func append(
        _ bytes: UnsafeRawBufferPointer
    ) -> Int {
        guard !bytes.isEmpty else {
            return 0
        }

        if writableCount == 0 && readIndex > 0 {
            compact()
        }

        let count = min(
            writableCount,
            bytes.count
        )

        guard count > 0 else {
            return 0
        }

        let index = writeIndex

        storage.withUnsafeMutableBytes { rawBuffer in
            guard let destination = rawBuffer.baseAddress,
                  let source = bytes.baseAddress
            else {
                preconditionFailure("non-empty buffer copy must have base addresses")
            }

            destination
                .advanced(by: index)
                .copyMemory(
                    from: source,
                    byteCount: count
                )
        }

        writeIndex += count

        return count
    }

    /// Moves the unread tail to index zero so consumed prefix storage becomes reusable.
    ///
    /// Compaction is deliberately explicit because it is a payload copy. The unread
    /// suffix overlaps its destination when it moves toward index zero, so this uses
    /// `memmove` rather than a scalar Swift loop or non-overlap copy primitive. A ring
    /// buffer can still avoid this payload movement entirely; benchmarks decide whether
    /// that representation is worth its two-region mechanics.
    ///
    /// If the buffer is empty, compaction only resets the cursors and copies nothing.
    package mutating func compact() {
        let count = readableCount

        guard count > 0 else {
            readIndex = 0
            writeIndex = 0
            return
        }

        guard readIndex > 0 else {
            return
        }

        compactionCallCount += 1
        compactedByteCount += UInt64(count)

        storage.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                preconditionFailure("non-empty compaction must have a base address")
            }

            let source = base.advanced(by: readIndex)

            #if canImport(Darwin)
            _ = Darwin.memmove(base, source, count)
            #elseif canImport(Glibc)
            _ = Glibc.memmove(base, source, count)
            #endif
        }

        readIndex = 0
        writeIndex = count
    }
}
