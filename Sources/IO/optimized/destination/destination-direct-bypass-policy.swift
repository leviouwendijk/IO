package enum DestinationDirectBypassPolicy: Sendable, Equatable {
    case larger_than_buffer
    case at_least_buffer

    @inline(__always)
    package func shouldBypass(
        byteCount: Int,
        bufferCapacity: Int
    ) -> Bool {
        switch self {
        case .larger_than_buffer:
            byteCount > bufferCapacity
        case .at_least_buffer:
            byteCount >= bufferCapacity
        }
    }
}
