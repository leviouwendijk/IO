/// Terminal state of one `Source.stream(to:)` attempt.
///
/// Streaming is incremental rather than an all-or-nothing promise. The result always
/// carries the number of bytes transferred during *this invocation*, allowing callers to
/// account for progress before EOF, limits, or backpressure stopped the operation.
///
/// `stream` does not flush the Destination. Acceptance into Destination and downstream
/// flush semantics are deliberately separate operations.
public enum StreamResult: Sendable, Equatable {
    /// The Source reached normal EOF after transferring this many bytes.
    case end(transferred: UInt64)

    /// The caller-supplied transfer limit was reached exactly.
    case limit(transferred: UInt64)

    /// The Source remained live but could not currently produce additional bytes.
    case source_unavailable(transferred: UInt64)

    /// The Destination could not currently accept additional bytes.
    case destination_unavailable(transferred: UInt64)

    /// Uniform access to the progress made regardless of the stopping reason.
    public var transferredByteCount: UInt64 {
        switch self {
        case .end(let transferred),
             .limit(let transferred),
             .source_unavailable(let transferred),
             .destination_unavailable(let transferred):
            return transferred
        }
    }
}
