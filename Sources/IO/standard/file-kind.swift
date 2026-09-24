public enum FileKind: String, Sendable, Hashable, Codable {
    case file
    case directory
    case symlink
    case other
}
