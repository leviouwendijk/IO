public enum DestinationDrain: Sendable, Equatable {
    case bytes(PositiveByteCount)
    case unavailable
}

public enum DestinationFlush: Sendable, Equatable {
    case complete
    case unavailable
}

/// Copyable diagnostic snapshot produced by a Destination backend on explicit request.
public struct DestinationBackendInspection: Sendable, Equatable {
    public let capturedBytes: [UInt8]?

    public init(
        capturedBytes: [UInt8]? = nil
    ) {
        self.capturedBytes = capturedBytes
    }
}

/// Runtime-selected endpoint contract that consumes bytes from a `Destination`.
///
/// Backends expose both scalar and two-region drains. Simple backends may implement only
/// `drain(_:)`; the default vector implementation drains the first non-empty logical
/// region. Backends with scatter/gather support override the two-region requirement.
///
/// `~Copyable` permits uniquely owned resource backends without requiring reference boxes.
public protocol DestinationBackend:
    IOReadinessProviding,
    ~Copyable
{
    mutating func drain(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationDrain

    mutating func drain(
        first: UnsafeRawBufferPointer,
        second: UnsafeRawBufferPointer
    ) throws -> DestinationDrain

    mutating func flush() throws -> DestinationFlush

    /// Makes bytes already drained to the backend durable on stable storage.
    /// Separate from `flush()`, which is logical only.
    mutating func synchronize() throws

    /// Produces a detached, copyable observation of backend state for diagnostics/tests.
    mutating func inspect() -> DestinationBackendInspection
}

public extension DestinationBackend where Self: ~Copyable {
    mutating func drain(
        first: UnsafeRawBufferPointer,
        second: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        if !first.isEmpty {
            return try drain(first)
        }
        if !second.isEmpty {
            return try drain(second)
        }
        return .unavailable
    }

    mutating func flush() throws -> DestinationFlush {
        .complete
    }

    mutating func synchronize() throws {
    }

    mutating func inspect() -> DestinationBackendInspection {
        .init()
    }
}
