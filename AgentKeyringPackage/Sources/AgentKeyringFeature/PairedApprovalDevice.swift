import CryptoKit
import Foundation

public enum PairedDeviceStoreError: Error, Sendable {
    case alreadyPaired
    case notPaired
    case changeInProgress
}

public struct PairedApprovalDevice: Codable, Equatable, Sendable {
    /// P-256 X9.63 bytes are the device's identity in the signed store.
    public let publicKey: Data
    public let name: String
    public let pairedAt: Date

    public init(publicKey: P256.Signing.PublicKey, name: String, pairedAt: Date = Date()) {
        self.publicKey = publicKey.x963Representation
        self.name = name
        self.pairedAt = pairedAt
    }
}
