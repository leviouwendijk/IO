import Foundation

public enum IOConcurrency: Sendable, Hashable, Codable {
    case serial
    case automatic
    case limited(Int)
}

extension IOConcurrency {
    func limit(
        for jobCount: Int
    ) -> Int {
        guard jobCount > 0 else {
            return 0
        }

        switch self {
        case .serial:
            return 1

        case .automatic:
            let suggested = max(
                2,
                min(
                    8,
                    ProcessInfo.processInfo.activeProcessorCount / 2
                )
            )

            return min(
                jobCount,
                suggested
            )

        case .limited(let value):
            return min(
                jobCount,
                max(
                    1,
                    value
                )
            )
        }
    }
}
