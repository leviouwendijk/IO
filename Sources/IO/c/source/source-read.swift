/// Result of asking a `SourceBackend` to populate a borrowed writable span.
///
/// Every case communicates endpoint state separately from byte-count data. In
/// particular, zero progress is not encoded as `.bytes(0)`.
public enum SourceRefill: Sendable, Equatable {
    /// The backend produced these bytes and expects that more may follow later.
    case bytes(PositiveByteCount)

    /// The backend produced these final bytes and simultaneously knows the source has
    /// reached normal EOF.
    ///
    /// This avoids requiring an otherwise pointless extra backend call merely to learn
    /// that the previous payload was the last payload.
    case final_bytes(PositiveByteCount)

    /// The source is exhausted and produced no additional bytes.
    ///
    /// EOF is normal control flow, not an error.
    case end

    /// The source remains valid but cannot make byte progress right now.
    ///
    /// The byte-stream layer deliberately does not prescribe *why* progress is
    /// unavailable or how to wait. A future execution capability may map this to
    /// polling, suspension, blocking, event registration, etc.
    case unavailable

    /// The backend made no semantic progress because its underlying operation was
    /// interrupted and should be retried immediately by `Source`.
    case retry
}

/// State exposed by `Source.prepare()` and `Source.requestMore()`.
///
/// This tells higher-level algorithms what the Source can currently provide without
/// collapsing buffered data, EOF, and temporary backpressure into magic integers.
public enum SourceAvailability: Sendable, Equatable {
    /// At least one readable byte is buffered.
    case bytes

    /// The endpoint has reached EOF and no request for more endpoint data is necessary.
    case end

    /// No additional bytes are currently available, but the endpoint remains live.
    case unavailable

    /// The caller explicitly requested more data while the buffer had no contiguous room.
    ///
    /// This is primarily relevant to `requestMore()`, where callers such as streaming
    /// codecs may deliberately retain an unread suffix and ask to append more bytes
    /// behind it.
    case buffer_full
}

/// Result of the copying convenience API `Source.read(into:)`.
///
/// The lower-level, preferred parser/codec path is `withBytes` + `consume`, which can
/// inspect buffered data without an extra copy. `SourceRead` exists for consumers that
/// genuinely want bytes copied into caller-owned storage.
public enum SourceRead: Sendable, Equatable {
    /// Positive number of bytes copied into the caller's output span.
    case bytes(PositiveByteCount)

    /// Normal EOF with no bytes copied.
    case end

    /// The Source could not currently obtain data from its backend.
    case unavailable

    /// The Source was unable to obtain a writable refill region.
    ///
    /// This should be unusual through `read(into:)` because `prepare()` only refills an
    /// empty buffer, but the state remains explicit rather than hidden.
    case buffer_full

    /// The caller provided a zero-length output span.
    ///
    /// No backend work is performed for an empty request.
    case empty
}
