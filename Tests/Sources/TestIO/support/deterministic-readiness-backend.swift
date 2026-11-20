import IO

/// Deterministic readiness backend for schedule/backpressure tests.
struct DeterministicReadinessBackend: ReadinessBackend, Sendable {
    private var registrations: [ReadinessToken: ReadinessInterest] = [:]
    private var queued: [ReadinessEvent] = []

    init() {}

    mutating func register(
        token: ReadinessToken,
        descriptor: Int32,
        interest: ReadinessInterest
    ) throws {
        _ = descriptor
        registrations[token] = interest
    }

    mutating func remove(token: ReadinessToken) throws {
        registrations.removeValue(forKey: token)
    }

    mutating func enqueue(_ event: ReadinessEvent) {
        guard let interest = registrations[event.token] else { return }
        let filtered = event.ready.intersection(interest)
        guard !filtered.isEmpty else { return }
        queued.append(.init(token: event.token, ready: filtered))
    }

    mutating func poll(
        maximumEvents: Int
    ) throws -> [ReadinessEvent] {
        guard maximumEvents > 0, !queued.isEmpty else { return [] }
        let count = min(maximumEvents, queued.count)
        let result = Array(queued.prefix(count))
        queued.removeFirst(count)
        return result
    }
}
