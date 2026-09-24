/// Copyable observation of Destination/backend boundary work.
public struct DestinationStatistics: Sendable, Equatable {
    /// Number of calls made through `DestinationBackend.drain`.
    public let drainCallCount: UInt64

    /// Total number of bytes accepted by the backend through drain calls.
    public let drainedByteCount: UInt64

    /// Number of backend flush calls issued by `Destination.flush()`.
    public let flushCallCount: UInt64

    package init(
        drainCallCount: UInt64,
        drainedByteCount: UInt64,
        flushCallCount: UInt64
    ) {
        self.drainCallCount = drainCallCount
        self.drainedByteCount = drainedByteCount
        self.flushCallCount = flushCallCount
    }
}
