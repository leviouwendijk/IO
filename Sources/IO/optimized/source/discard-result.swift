/// Terminal state of one bounded `Source.discard(maximumCount:)` attempt.
///
/// Discarding expresses that byte values themselves are irrelevant. Preserving this
/// semantic intent may later allow endpoints to skip copies or use specialized discard
/// behavior instead of materializing data unnecessarily.
public enum DiscardResult: Sendable, Equatable {
    /// Normal EOF was reached after discarding this many bytes.
    case end(discarded: UInt64)

    /// The requested discard limit was reached exactly.
    case limit(discarded: UInt64)

    /// The Source remains valid but could not currently produce more bytes to discard.
    case unavailable(discarded: UInt64)

    /// Uniform access to byte progress regardless of why this discard attempt stopped.
    public var discardedByteCount: UInt64 {
        switch self {
        case .end(let discarded),
             .limit(let discarded),
             .unavailable(let discarded):
            return discarded
        }
    }
}
