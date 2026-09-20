public extension Source {
    /// Streams bytes from this Source into a Destination until normal EOF or backpressure.
    ///
    /// This is the semantic end-to-end transfer operation. Keeping the intent as
    /// `stream(to:)` leaves room for future endpoint-specific fast paths such as a
    /// file-to-socket kernel transfer without changing higher-level call sites.
    ///
    /// The current implementation is the generic fallback: borrow Source bytes, offer
    /// them to Destination, and consume only the prefix Destination accepted.
    ///
    /// This method intentionally does **not** call `destination.flush()`. Streaming and
    /// flush have different semantics; callers decide when downstream visibility should
    /// be requested.
    mutating func stream(
        to destination: inout Destination
    ) throws -> StreamResult {
        try stream(
            to: &destination,
            limit: nil
        )
    }

    /// Streams at most `maximumCount` bytes into a Destination.
    ///
    /// Bounded transfer is a first-class operation because "stream everything" can be an
    /// unsafe default for untrusted or extremely large sources. A zero limit completes
    /// immediately with `.limit(transferred: 0)`.
    mutating func stream(
        to destination: inout Destination,
        maximumCount: UInt64
    ) throws -> StreamResult {
        try stream(
            to: &destination,
            limit: maximumCount
        )
    }
}

private extension Source {
    /// Generic streaming state machine shared by bounded and unbounded entry points.
    ///
    /// The state machine never consumes Source bytes merely because they were offered.
    /// Consumption occurs only after Destination reports that it accepted them. This is
    /// the core backpressure invariant preventing data loss on partial/unavailable writes.
    mutating func stream(
        to destination: inout Destination,
        limit: UInt64?
    ) throws -> StreamResult {
        var transferred: UInt64 = 0

        while true {
            if let limit, transferred == limit {
                return .limit(
                    transferred: transferred
                )
            }

            switch try prepare() {
            case .bytes:
                var offeredCount = 0
                let result = try withBytes { readable in
                    offeredCount = boundedReadableCount(
                        availableCount: readable.count,
                        transferred: transferred,
                        limit: limit
                    )

                    let offered = UnsafeRawBufferPointer(
                        start: readable.baseAddress,
                        count: offeredCount
                    )

                    return try destination.write(
                        offered
                    )
                }

                switch result {
                case .complete:
                    try consume(
                        offeredCount
                    )
                    transferred += UInt64(
                        offeredCount
                    )

                case .partial(let count):
                    try consume(
                        count.value
                    )
                    transferred += UInt64(
                        count.value
                    )
                    return .destination_unavailable(
                        transferred: transferred
                    )

                case .unavailable:
                    return .destination_unavailable(
                        transferred: transferred
                    )
                }

            case .end:
                return .end(
                    transferred: transferred
                )

            case .unavailable:
                return .source_unavailable(
                    transferred: transferred
                )

            case .buffer_full:
                preconditionFailure(
                    "An empty prepared source cannot have a full buffer."
                )
            }
        }
    }

    /// Calculates how much of the currently buffered Source region may be offered without
    /// exceeding the caller's `UInt64` transfer limit.
    ///
    /// The `Int.max` branch avoids an unsafe narrowing conversion on platforms where the
    /// remaining `UInt64` range exceeds what `Int` can represent.
    func boundedReadableCount(
        availableCount: Int,
        transferred: UInt64,
        limit: UInt64?
    ) -> Int {
        guard let limit else {
            return availableCount
        }

        let remaining = limit - transferred

        if remaining >= UInt64(Int.max) {
            return bufferedByteCount
        }

        return min(
            bufferedByteCount,
            Int(remaining)
        )
    }
}
