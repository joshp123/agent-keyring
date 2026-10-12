import CloudKit
import CryptoKit
import Foundation
import Security

public enum PairingFailure: Error, Equatable, Sendable {
    case invalidCode
    case expired
    case invalidRequest
    case confirmationCodeMismatch
    case authenticationFailed
    case alreadyUsed
}

/// Memory-only QR payload. It must never be saved or logged.
public struct PairingCode: Sendable {
    public static let lifetimeSeconds: TimeInterval = 300
    public let id: UUID
    public let secret: Data
    public let expiresAt: Date

    public init(now: Date = Date()) throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        id = UUID()
        secret = Data(bytes)
        expiresAt = now.addingTimeInterval(Self.lifetimeSeconds)
    }

    public var qrPayload: String {
        var components = URLComponents()
        components.scheme = "agent-keyring"
        components.host = "pair"
        components.path = "/v1/\(id.uuidString)"
        components.queryItems = [
            URLQueryItem(name: "secret", value: secret.base64EncodedString()),
            URLQueryItem(name: "expires", value: String(expiresAt.timeIntervalSince1970))
        ]
        return components.string!
    }

    public init(qrPayload: String, now: Date = Date()) throws {
        guard let components = URLComponents(string: qrPayload),
            components.scheme == "agent-keyring", components.host == "pair",
            components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
            components.path.hasPrefix("/v1/"),
            let id = UUID(uuidString: String(components.path.dropFirst(4))),
            let items = components.queryItems, items.count == 2,
            let secretText = items.first(where: { $0.name == "secret" })?.value,
            let secret = Data(base64Encoded: secretText), secret.count == 32,
            let expiryText = items.first(where: { $0.name == "expires" })?.value,
            let expiry = TimeInterval(expiryText), expiry.isFinite
        else { throw PairingFailure.invalidCode }
        guard now.timeIntervalSince1970 < expiry else { throw PairingFailure.expired }
        self.id = id
        self.secret = secret
        self.expiresAt = Date(timeIntervalSince1970: expiry)
    }
}

public struct PairingRequest: Sendable {
    public let pairingID: UUID
    public let publicKey: Data
    public let deviceName: String
    public let authenticationCode: Data

    public init(pairingID: UUID, publicKey: Data, deviceName: String, authenticationCode: Data) {
        self.pairingID = pairingID
        self.publicKey = publicKey
        self.deviceName = deviceName
        self.authenticationCode = authenticationCode
    }

    public init(code: PairingCode, publicKey: Data, deviceName: String) {
        let bytes = Self.canonicalBytes(pairingID: code.id, publicKey: publicKey, deviceName: deviceName)
        self.init(pairingID: code.id, publicKey: publicKey, deviceName: deviceName,
            authenticationCode: Data(HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: code.secret))))
    }

    /// v1: domain prefix, 16 UUID bytes, UInt32 big-endian length + X9.63
    /// public key, UInt32 big-endian length + verbatim UTF-8 device name.
    public static func canonicalBytes(pairingID: UUID, publicKey: Data, deviceName: String) -> Data {
        var bytes = Data("AgentKeyring.pairing.v1\0".utf8)
        var uuid = pairingID.uuid
        withUnsafeBytes(of: &uuid) { bytes.append(contentsOf: $0) }
        for value in [publicKey, Data(deviceName.utf8)] {
            var length = UInt32(value.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(value)
        }
        return bytes
    }

    public func verify(code: PairingCode, now: Date = Date()) throws {
        guard pairingID == code.id else { throw PairingFailure.invalidRequest }
        guard now < code.expiresAt else { throw PairingFailure.expired }
        guard code.secret.count == 32, authenticationCode.count == 32,
            HMAC<SHA256>.isValidAuthenticationCode(authenticationCode,
                authenticating: Self.canonicalBytes(pairingID: pairingID, publicKey: publicKey, deviceName: deviceName),
                using: SymmetricKey(data: code.secret))
        else { throw PairingFailure.authenticationFailed }
        guard !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            deviceName.utf8.count <= 256,
            !deviceName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            (try? P256.Signing.PublicKey(x963Representation: publicKey)) != nil
        else { throw PairingFailure.invalidRequest }
    }

    public static func confirmationCode(publicKey: Data) -> String {
        let prefix = SHA256.hash(data: publicKey).prefix(4)
        let value = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }

    public static func fingerprint(publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

public enum PairingCloudRecords {
    public static let zone = CKRecordZone.ID(zoneName: "PairingRequests", ownerName: CKCurrentUserDefaultName)

    public static func recordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zone)
    }

    public static func record(_ request: PairingRequest) -> CKRecord {
        let record = CKRecord(recordType: "PairingRequest", recordID: recordID(request.pairingID))
        record["publicKey"] = request.publicKey as CKRecordValue
        record.encryptedValues["deviceName"] = request.deviceName as CKRecordValue
        record["authenticationCode"] = request.authenticationCode as CKRecordValue
        return record
    }

    public static func request(from record: CKRecord, pairingID: UUID) throws -> PairingRequest {
        guard record.recordType == "PairingRequest", record.recordID == recordID(pairingID),
            let key = record["publicKey"] as? Data, let name = record.encryptedValues["deviceName"] as? String,
            let authenticationCode = record["authenticationCode"] as? Data
        else { throw PairingFailure.invalidRequest }
        return PairingRequest(pairingID: pairingID, publicKey: key, deviceName: name, authenticationCode: authenticationCode)
    }
}
