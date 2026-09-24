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

    /// Fingerprint of an ordered list of lines.
    ///
    /// Each line is framed by its UTF-8 byte count before hashing, so the shape of
    /// the list is part of the fingerprint: `["a\nb"]` and `["a", "b"]` differ, as do
    /// `["a", ""]` and `["a\n"]`. The algorithm is reported as `fnv1a64-lines`
    /// because these values are not comparable with fingerprints of joined text.
    public static func fingerprint(
        for lines: [String]
    ) -> Self? {
        guard !lines.isEmpty else {
            return nil
        }

        var hash = fnv1a64OffsetBasis

        for line in lines {
            var length = UInt64(
                line.utf8.count
            ).littleEndian

            withUnsafeBytes(
                of: &length
            ) {
                for byte in $0 {
                    hash = fnv1a64Step(
                        hash,
                        byte
                    )
                }
            }

            for byte in line.utf8 {
                hash = fnv1a64Step(
                    hash,
                    byte
                )
            }
        }

        return .init(
            algorithm: "fnv1a64-lines",
            value: String(
                format: "%016llx",
                hash
            )
        )
    }

    private static let fnv1a64OffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnv1a64Prime: UInt64 = 1_099_511_628_211

    @inline(__always)
    private static func fnv1a64Step(
        _ hash: UInt64,
        _ byte: UInt8
    ) -> UInt64 {
        (hash ^ UInt64(byte)) &* fnv1a64Prime
    }

    private static func fnv1a64(
        _ bytes: Data
    ) -> Self {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211

        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            let buffer = baseAddress.assumingMemoryBound(
                to: UInt8.self
            )

            var index = 0

            while index < rawBuffer.count {
                hash ^= UInt64(
                    buffer[index]
                )
                hash &*= prime
                index += 1
            }
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
