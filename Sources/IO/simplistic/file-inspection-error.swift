import Foundation

public enum FileInspectionError: Error, Sendable, LocalizedError, Hashable {
    case io(
        URL,
        message: String
    )

    public var errorDescription: String? {
        switch self {
        case .io(let url, let message):
            return "I/O error while inspecting \(url.path): \(message)"
        }
    }
}
