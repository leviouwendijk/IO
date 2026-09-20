/// How a delivered line fragment relates to the logical line boundary.
public enum ByteLineFragmentEnding: Sendable, Equatable {
    /// More bytes belonging to the same logical line may follow in a later fragment.
    case none

    /// The fragment reaches a line-feed byte. The line-feed itself is not included in
    /// `ByteLineFragment.bytes` or `byteRange`.
    case line_feed

    /// The source reached EOF after this logical line without a trailing line-feed.
    case end
}

/// Decision returned by a `ByteLineScanner` fragment callback.
public enum ByteLineScanDirective: Sendable, Equatable {
    case `continue`
    case stop
}

/// Why one scanner drive stopped.
public enum ByteLineScanResult: Sendable, Equatable {
    case end
    case stopped
    case unavailable
}

/// Borrowed, non-owning view of one contiguous fragment of a logical byte line.
///
/// `bytes` points into Source-owned storage and is valid only during the callback that
/// receives this value. A logical line may arrive as many fragments when it crosses
/// Source-buffer boundaries. `lineStartOffset` and `byteRange` are absolute byte offsets
/// in the source stream, making boundary verification independent of UTF-8 decoding.
public struct ByteLineFragment {
    public let lineNumber: UInt64
    public let lineStartOffset: UInt64
    public let byteRange: Range<UInt64>
    public let bytes: UnsafeRawBufferPointer
    public let ending: ByteLineFragmentEnding
}

/// Copyable observation of byte-line scanning work.
public struct ByteLineScannerStatistics: Sendable, Equatable {
    public let bytesExamined: UInt64
    public let fragmentCount: UInt64
    public let completedLineCount: UInt64
    public let peakSourceBufferedByteCount: Int
    public let source: SourceStatistics
}

/// Uniquely-owned byte-line scanner layered directly over a `Source`.
///
/// The scanner intentionally understands only byte line boundaries (`LF`). It does not
/// decode UTF-8 and therefore cannot corrupt multi-byte scalars when Source refills split
/// them arbitrarily. CRLF policy remains above this primitive: a consumer that wants text
/// lines may trim a trailing `CR` from the final fragments it accumulates.
///
/// The scanner consumes ownership of its Source. Copying a scanner halfway through a
/// stream would duplicate logical line/offset state, so the type is deliberately
/// noncopyable.
public struct ByteLineScanner: ~Copyable {
    private var source: Source
    private var lineNumber: UInt64
    private var lineStartOffset: UInt64
    private var absoluteOffset: UInt64
    private var currentLineHasBytes: Bool
    private var finished: Bool

    private var bytesExamined: UInt64
    private var fragmentCount: UInt64
    private var completedLineCount: UInt64
    private var peakSourceBufferedByteCount: Int

    public init(
        source: consuming Source
    ) {
        self.source = consume source
        self.lineNumber = 1
        self.lineStartOffset = 0
        self.absoluteOffset = 0
        self.currentLineHasBytes = false
        self.finished = false
        self.bytesExamined = 0
        self.fragmentCount = 0
        self.completedLineCount = 0
        self.peakSourceBufferedByteCount = 0
    }

    public var statistics: ByteLineScannerStatistics {
        borrowing get {
            .init(
                bytesExamined: bytesExamined,
                fragmentCount: fragmentCount,
                completedLineCount: completedLineCount,
                peakSourceBufferedByteCount: peakSourceBufferedByteCount,
                source: source.statistics
            )
        }
    }

    /// Drives scanning with the measured production-default delimiter kernel.
    ///
    /// `ByteMatch.libc` remains the default because it performs best for ordinary
    /// stop-capable line scanning. Workloads that benefit from dense/all-match discovery
    /// can choose another compile-time kernel through `scan(using:_:)`.
    public mutating func scan(
        _ body: (ByteLineFragment) throws -> ByteLineScanDirective
    ) throws -> ByteLineScanResult {
        try scan(
            using: ByteMatch.libc.self,
            body
        )
    }

    /// Drives scanning with an explicitly selected compile-time byte-match kernel.
    ///
    /// The kernel is a generic type parameter rather than an existential so selecting a
    /// task-specific algorithm does not force witness-table dispatch into the inner byte
    /// search loop.
    public mutating func scan<Kernel: ByteMatchKernel>(
        using kernel: Kernel.Type,
        _ body: (ByteLineFragment) throws -> ByteLineScanDirective
    ) throws -> ByteLineScanResult {
        if finished {
            return .end
        }

        scanLoop: while true {
            switch try source.prepare() {
            case .bytes:
                peakSourceBufferedByteCount = max(
                    peakSourceBufferedByteCount,
                    source.bufferedByteCount
                )

                var processed = 0
                var localLineNumber = lineNumber
                var localLineStartOffset = lineStartOffset
                var localAbsoluteOffset = absoluteOffset
                var localCurrentLineHasBytes = currentLineHasBytes
                var localFragmentCount = fragmentCount
                var localCompletedLineCount = completedLineCount
                var shouldStop = false

                try source.withBytes { readable in
                    var fragmentStart = 0
                    let readableBase = readable.baseAddress

                    _ = try kernel.walk(
                        readable,
                        needle: 0x0A,
                        from: 0
                    ) { index in
                        let fragmentCount = index - fragmentStart
                        let start = readableBase.map {
                            $0.advanced(by: fragmentStart)
                        }
                        let fragmentBytes = UnsafeRawBufferPointer(
                            start: start,
                            count: fragmentCount
                        )
                        let fragmentStartOffset = localAbsoluteOffset
                        let fragmentEndOffset = fragmentStartOffset + UInt64(fragmentCount)

                        localFragmentCount += 1
                        localCompletedLineCount += 1

                        let directive = try body(
                            .init(
                                lineNumber: localLineNumber,
                                lineStartOffset: localLineStartOffset,
                                byteRange: fragmentStartOffset..<fragmentEndOffset,
                                bytes: fragmentBytes,
                                ending: .line_feed
                            )
                        )

                        let consumedCount = fragmentCount + 1
                        processed += consumedCount
                        localAbsoluteOffset += UInt64(consumedCount)
                        localLineNumber += 1
                        localLineStartOffset = localAbsoluteOffset
                        localCurrentLineHasBytes = false
                        fragmentStart = index + 1

                        if directive == .stop {
                            shouldStop = true
                            return .stop
                        }

                        return .continue
                    }

                    if !shouldStop,
                       fragmentStart < readable.count
                    {
                        let fragmentCount = readable.count - fragmentStart
                        let start = readableBase.map {
                            $0.advanced(by: fragmentStart)
                        }
                        let fragmentBytes = UnsafeRawBufferPointer(
                            start: start,
                            count: fragmentCount
                        )
                        let fragmentStartOffset = localAbsoluteOffset
                        let fragmentEndOffset = fragmentStartOffset + UInt64(fragmentCount)

                        localFragmentCount += 1

                        let directive = try body(
                            .init(
                                lineNumber: localLineNumber,
                                lineStartOffset: localLineStartOffset,
                                byteRange: fragmentStartOffset..<fragmentEndOffset,
                                bytes: fragmentBytes,
                                ending: .none
                            )
                        )

                        processed += fragmentCount
                        localAbsoluteOffset += UInt64(fragmentCount)
                        localCurrentLineHasBytes = true

                        if directive == .stop {
                            shouldStop = true
                        }
                    }
                }

                try source.consume(
                    processed
                )

                bytesExamined += UInt64(
                    processed
                )
                lineNumber = localLineNumber
                lineStartOffset = localLineStartOffset
                absoluteOffset = localAbsoluteOffset
                currentLineHasBytes = localCurrentLineHasBytes
                fragmentCount = localFragmentCount
                completedLineCount = localCompletedLineCount

                if shouldStop {
                    return .stopped
                }

            case .end:
                if currentLineHasBytes {
                    fragmentCount += 1
                    completedLineCount += 1

                    let directive = try body(
                        .init(
                            lineNumber: lineNumber,
                            lineStartOffset: lineStartOffset,
                            byteRange: absoluteOffset..<absoluteOffset,
                            bytes: UnsafeRawBufferPointer(
                                start: nil,
                                count: 0
                            ),
                            ending: .end
                        )
                    )

                    currentLineHasBytes = false

                    if directive == .stop {
                        finished = true
                        return .stopped
                    }
                }

                finished = true
                return .end

            case .unavailable:
                return .unavailable

            case .buffer_full:
                preconditionFailure(
                    "An empty prepared Source cannot have a full buffer."
                )
            }
        }
    }

}
