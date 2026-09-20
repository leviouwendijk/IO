/// Runtime-selected endpoint contract that can produce bytes for a `Source`.
///
/// Backends expose both the ordinary single-region operation and a two-region refill
/// boundary. Simple backends may implement only `refill(into:)`; the default vector
/// implementation fills the first non-empty region. Backends that can exploit scatter
/// input (for example POSIX `readv`) override the two-region requirement directly.
///
/// The protocol suppresses Swift's default `Copyable` requirement so uniquely owned
/// resource backends (file descriptors, sockets, pipes, etc.) can conform without being
/// boxed in a reference type.
public protocol SourceBackend: ~Copyable {
    mutating func refill(
        into bytes: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill

    mutating func refill(
        first: UnsafeMutableRawBufferPointer,
        second: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill
}

public extension SourceBackend where Self: ~Copyable {
    mutating func refill(
        first: UnsafeMutableRawBufferPointer,
        second: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        if !first.isEmpty {
            return try refill(into: first)
        }
        if !second.isEmpty {
            return try refill(into: second)
        }
        return .unavailable
    }
}
