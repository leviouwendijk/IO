/// Result of asking `Destination.write` to accept caller-owned bytes.
///
/// "Accepted" means the caller may stop retaining/resubmitting that prefix. Accepted
/// bytes may already have reached the backend or may still reside in Destination's own
/// staging buffer.
///
/// This distinction lets Destination expose real backpressure without requiring
/// unbounded buffering.
public enum DestinationWrite: Sendable, Equatable {
    /// Every byte in the caller's request was accepted.
    case complete

    /// A positive prefix was accepted before the Destination encountered backpressure.
    ///
    /// The caller remains responsible for the unaccepted suffix.
    case partial(PositiveByteCount)

    /// No bytes from the request were accepted because progress is currently unavailable.
    case unavailable
}
