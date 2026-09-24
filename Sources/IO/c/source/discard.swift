public extension Source {
    /// Consumes and forgets at most `maximumCount` bytes from the Source.
    ///
    /// This operation intentionally preserves the semantic fact that the caller does not
    /// need the payload. The current generic implementation still refills the Source into
    /// its ordinary buffer and advances cursors, but future specialized endpoints may be
    /// able to exploit discard intent more directly.
    ///
    /// The explicit limit keeps unbounded consumption from becoming the low-level
    /// default. A zero limit returns `.limit(discarded: 0)` without endpoint work.
    mutating func discard(
        maximumCount: UInt64
    ) throws -> DiscardResult {
        // Tracks progress made by this invocation only.
        var discarded: UInt64 = 0

        while discarded < maximumCount {
            switch try prepare() {
            case .bytes:
                // Remaining caller-authorized discard budget.
                let remaining = maximumCount - discarded

                // Number of currently buffered bytes we may consume without exceeding
                // the UInt64 limit or performing an unsafe narrowing conversion.
                let count: Int

                if remaining >= UInt64(Int.max) {
                    count = bufferedByteCount
                } else {
                    count = min(
                        bufferedByteCount,
                        Int(remaining)
                    )
                }

                try consume(
                    count
                )

                discarded += UInt64(
                    count
                )

            case .end:
                return .end(
                    discarded: discarded
                )

            case .unavailable:
                return .unavailable(
                    discarded: discarded
                )

            case .buffer_full:
                // `prepare()` only requests endpoint data when the buffer is empty, so a
                // full-buffer state here would indicate an internal invariant violation.
                preconditionFailure(
                    "An empty prepared source cannot have a full buffer."
                )
            }
        }

        return .limit(
            discarded: discarded
        )
    }
}
