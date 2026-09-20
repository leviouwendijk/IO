/// Violations of the contract between shared stream mechanics and a backend/caller.
///
/// These are different from endpoint failures such as a file descriptor error. They mean
/// one participant claimed something impossible relative to the bytes it was given.
///
/// Keeping these failures explicit is useful while the architecture is experimental:
/// backend implementations fail loudly instead of silently corrupting cursor state.
public enum StreamContractError: Error, Sendable, Equatable {
    /// `Source.consume` was asked to move its cursor backwards.
    ///
    /// Negative consumption has no stream meaning and indicates caller misuse.
    case negative_consume(Int)

    /// A caller tried to consume bytes that are not currently buffered by the Source.
    ///
    /// `available` is the exact number of readable bytes at the time of the request.
    case consume_exceeds_available(
        requested: Int,
        available: Int
    )

    /// A Source backend claimed to have initialized more bytes than the writable span
    /// passed to `refill`.
    ///
    /// Accepting this claim would move the Source write cursor beyond valid storage.
    case source_reported_too_many_bytes(
        reported: Int,
        writable: Int
    )

    /// A Destination backend claimed to have consumed more bytes than it was offered.
    ///
    /// Accepting this claim would cause Destination to discard data the backend never
    /// actually saw.
    case destination_reported_too_many_bytes(
        reported: Int,
        offered: Int
    )
}
