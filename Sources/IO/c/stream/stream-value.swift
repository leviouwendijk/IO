/// Construction failures for value types whose invariants are stronger than `Int`.
///
/// These errors implement the parse-don't-validate rule at the stream boundary: once a
/// `PositiveByteCount` or `BufferCapacity` exists, downstream code can rely on its
/// invariant without repeatedly checking for zero or negative values.
public enum StreamValueError: Error, Sendable, Equatable {
    /// A value that must describe actual byte progress was zero or negative.
    ///
    /// Zero progress is represented semantically by states such as `unavailable`, not
    /// by smuggling `0` into a progress count.
    case non_positive_byte_count(Int)

    /// A buffer was requested with no usable storage.
    ///
    /// The current buffer implementation requires at least one byte of capacity.
    case non_positive_buffer_capacity(Int)
}

/// A byte count that is guaranteed to be strictly greater than zero.
///
/// This type is used only where *progress has definitely occurred*. It prevents APIs
/// such as `SourceRefill.bytes` and `DestinationDrain.bytes` from ambiguously carrying
/// zero. "No progress right now" is a different state and is represented explicitly.
///
/// The wrapper also makes backend contracts easier to audit: if a backend returns
/// `.bytes(count)`, the caller knows that the backend claims real progress.
public struct PositiveByteCount: Sendable, Hashable, Comparable {
    /// The validated positive integer count.
    ///
    /// Exposing the integer is intentional for low-level arithmetic. The invariant is
    /// preserved because construction remains controlled.
    public let value: Int

    /// Creates a positive byte count from untrusted or externally supplied integer data.
    ///
    /// - Throws: `StreamValueError.non_positive_byte_count` when `value <= 0`.
    public init(
        _ value: Int
    ) throws {
        guard value > 0 else {
            throw StreamValueError.non_positive_byte_count(
                value
            )
        }

        self.value = value
    }

    /// Orders progress counts by their underlying byte count.
    public static func < (
        lhs: Self,
        rhs: Self
    ) -> Bool {
        lhs.value < rhs.value
    }

    /// Creates a positive count for an internally proven value.
    ///
    /// This exists to avoid converting an already-proven internal invariant back into a
    /// throwing control flow. Callers of this helper must establish positivity first.
    /// The precondition is therefore a programmer invariant, not input validation.
    package static func knownPositive(
        _ value: Int
    ) -> Self {
        precondition(value > 0)

        return .init(
            validated: value
        )
    }

    /// Internal initializer used only after positivity has already been established.
    private init(
        validated value: Int
    ) {
        self.value = value
    }
}

/// A stream-buffer capacity that is guaranteed to be strictly greater than zero.
///
/// Capacity is deliberately a semantic value rather than an arbitrary `Int` passed
/// throughout the API. Buffer sizing will eventually be an important part of the cost
/// model: larger buffers reduce endpoint transitions but consume more memory and cache
/// per concurrent operation.
///
/// This type currently enforces only positivity. It intentionally does *not* impose a
/// global preferred size because useful sizes depend on endpoint and protocol semantics.
public struct BufferCapacity: Sendable, Hashable {
    /// Default staging-buffer capacity used when a caller has no workload-specific value.
    ///
    /// 64 KiB is an experimental baseline rather than a universal optimum. `expiotest`
    /// benchmarks this and other sizes against real workloads.
    public static let `default` = Self(
        validated: 64 * 1024
    )

    /// The validated number of bytes the buffer can hold.
    public let value: Int

    /// Creates a valid capacity.
    ///
    /// - Throws: `StreamValueError.non_positive_buffer_capacity` when `value <= 0`.
    public init(
        _ value: Int
    ) throws {
        guard value > 0 else {
            throw StreamValueError.non_positive_buffer_capacity(
                value
            )
        }

        self.value = value
    }

    /// Internal initializer used for compile-time-known valid capacities.
    private init(
        validated value: Int
    ) {
        precondition(value > 0)
        self.value = value
    }
}
