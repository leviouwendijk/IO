import Foundation

public struct ContentFingerprint: Codable, Sendable, Hashable, CustomStringConvertible {
    public let algorithm: String
    public let value: String

    public init(
        algorithm: String,
        value: String
    ) {
        self.algorithm = algorithm
        self.value = value
    }

    public var description: String {
        "\(algorithm):\(value)"
    }

    public static func fingerprint(
        for content: String
    ) -> Self {
        fingerprint(
            for: Data(
                content.utf8
            )
        )
    }

    public static func fingerprint(
        for data: Data
    ) -> Self {
        fnv1a64(
            data
        )
    }

    public static func fingerprint(
        for lines: [String]
    ) -> Self? {
        guard !lines.isEmpty else {
            return nil
        }

        return fingerprint(
            for: lines.joined(
                separator: "\n"
            )
        )
    }

    private static func fnv1a64(
        _ bytes: Data
    ) -> Self {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211

        for byte in bytes {
            hash ^= UInt64(
                byte
            )
            hash &*= prime
        }

        let value = String(
            format: "%016llx",
            hash
        )

        return .init(
            algorithm: "fnv1a64",
            value: value
        )
    }
}
