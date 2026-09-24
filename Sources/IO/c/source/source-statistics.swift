/// Copyable observation of a Source's backend-boundary work.
///
/// These counters live in `Source`, not in the backend, so observing them never requires
/// retaining or borrowing a second reference to mutable backend state.
public struct SourceStatistics: Sendable, Equatable {
    /// Number of calls made through `SourceBackend.refill`.
    ///
    /// `SystemFileSource` performs exactly one `read(2)` call per refill invocation, so
    /// this is also its exact read-syscall count.
    public let refillCallCount: UInt64

    /// Total number of payload bytes the backend reported into Source-owned storage.
    public let refilledByteCount: UInt64

    package init(
        refillCallCount: UInt64,
        refilledByteCount: UInt64
    ) {
        self.refillCallCount = refillCallCount
        self.refilledByteCount = refilledByteCount
    }
}
