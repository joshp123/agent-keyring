import CryptoKit
import Foundation

public enum TOTPGeneratorError: Error, Equatable, Sendable {
    case invalidConfiguration
}

public struct TOTPGenerator: Sendable {
    public init() {}

    public func code(
        secret: Data,
        period: UInt16,
        digits: UInt16,
        algorithm: MirrorTOTPAlgorithm,
        at date: Date = Date()
    ) throws -> String {
        guard !secret.isEmpty, period > 0, (6...10).contains(digits) else {
            throw TOTPGeneratorError.invalidConfiguration
        }

        var counter = UInt64(date.timeIntervalSince1970 / Double(period)).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let key = SymmetricKey(data: secret)
        let digest: Data
        switch algorithm {
        case .sha1:
            digest = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256:
            digest = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512:
            digest = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }

        guard let finalByte = digest.last else {
            throw TOTPGeneratorError.invalidConfiguration
        }
        let offset = Int(finalByte & 0x0F)
        guard offset + 3 < digest.count else {
            throw TOTPGeneratorError.invalidConfiguration
        }
        let binary =
            (UInt32(digest[offset] & 0x7F) << 24)
            | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8)
            | UInt32(digest[offset + 3])
        let modulus = UInt64(pow(10.0, Double(digits)))
        let value = UInt64(binary) % modulus
        return String(format: "%0*llu", Int(digits), value)
    }
}
