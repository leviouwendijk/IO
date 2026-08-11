import Foundation

public struct FileIdentity: Sendable, Hashable, Codable {
    public let deviceID: UInt64
    public let fileID: UInt64

    public init(
        deviceID: UInt64,
        fileID: UInt64
    ) {
        self.deviceID = deviceID
        self.fileID = fileID
    }
}
