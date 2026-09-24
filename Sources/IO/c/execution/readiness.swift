public struct ReadinessToken: RawRepresentable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

public struct ReadinessInterest: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let readable = Self(rawValue: 1 << 0)
    public static let writable = Self(rawValue: 1 << 1)
}

public struct ReadinessEvent: Hashable, Sendable {
    public let token: ReadinessToken
    public let ready: ReadinessInterest

    public init(token: ReadinessToken, ready: ReadinessInterest) {
        self.token = token
        self.ready = ready
    }
}

/// Scheduling boundary above synchronous Source/Destination byte movement.
///
/// Byte endpoints report `.unavailable`; a readiness backend decides when retrying that
/// endpoint can make sense. This keeps polling/event-loop policy out of parsers/codecs.
public protocol ReadinessBackend {
    mutating func register(
        token: ReadinessToken,
        descriptor: Int32,
        interest: ReadinessInterest
    ) throws

    mutating func remove(token: ReadinessToken) throws

    mutating func poll(
        maximumEvents: Int
    ) throws -> [ReadinessEvent]
}
