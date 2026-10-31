import AgentKeyringProtocol
import CryptoKit
import Foundation

/// The byte formats in internal/relaycrypto. Sign and hash the original bytes;
/// protobuf serialization is deliberately not treated as canonical.
public enum RelayCrypto {
    public static func hash(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
    public static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    public static func keyID(_ x963: Data) -> String { hex(hash(x963)) }
    public static func digest(_ domain: String, _ bytes: Data) -> Data { hash(Data((domain + "\0").utf8) + bytes) }

    public static func transcript(_ parts: [Data]) -> Data {
        var bytes = Data()
        for part in parts {
            var count = UInt32(part.count).bigEndian
            withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
            bytes.append(part)
        }
        return bytes
    }

    public static func pairTranscript(relaySPKI: Data, approverSPKI: Data, signingKey: Data, keySet: Data) -> Data {
        transcript([Data("agentkeyring.pair.v1\0".utf8), relaySPKI, approverSPKI, signingKey, keySet])
    }

    public static func enrolTranscript(relaySPKI: Data, clientSPKI: Data, receiverKey: Data, keySet: Data) -> Data {
        transcript([Data("agentkeyring.enrol.v1\0".utf8), relaySPKI, clientSPKI, receiverKey, keySet])
    }

    public static func fingerprint(_ transcript: Data) -> String {
        let encoded = hex(hash(transcript).prefix(16)).uppercased()
        return stride(from: 0, to: encoded.count, by: 4).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            return String(encoded[start..<encoded.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }

    public static func verify(signature: Data, statement: Data, publicKey: Data) throws -> Bool {
        try P256.Signing.PublicKey(x963Representation: publicKey)
            .isValidSignature(P256.Signing.ECDSASignature(derRepresentation: signature), for: statement)
    }

    public static func seal(_ contents: Agentkeyring_V1_BundleContents, receiverKey: Data,
        requestDigest: Data) throws -> Agentkeyring_V1_SealedBundle {
        let key = try P256.KeyAgreement.PublicKey(x963Representation: receiverKey)
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: .P256_SHA256_AES_GCM_256,
            info: Data("agentkeyring.bundle.v1".utf8))
        var plaintext = try contents.serializedData()
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        var bundle = Agentkeyring_V1_SealedBundle()
        bundle.encapsulatedKey = sender.encapsulatedKey
        bundle.ciphertext = try sender.seal(plaintext, authenticating: requestDigest)
        bundle.receiverKeyID = keyID(receiverKey)
        return bundle
    }

    static func loginCopyContents(item: MirrorItem) throws -> Agentkeyring_V1_AutomaticLoginContents {
        let resolver = CredentialResolver()
        let candidate = resolver.candidate(for: item)
        var contents = Agentkeyring_V1_AutomaticLoginContents()
        contents.loginID = item.id.uuidString
        contents.sites = item.origins.sorted()
        contents.username = candidate.username ?? ""
        if candidate.availableFields.contains(.password) { contents.password = try resolver.value(in: item, field: .password) }
        if candidate.availableFields.contains(.totp) {
            for credential in item.credentials {
                if case let .totp(secret, period, digits, _, algorithm, _) = credential {
                    contents.totpSeed = secret
                    contents.totpPeriodSeconds = Int32(period)
                    contents.totpDigits = Int32(digits)
                    contents.totpAlgorithm = algorithm.rawValue.uppercased()
                }
            }
        }
        return contents
    }

    static func sealLoginCopy(_ contents: Agentkeyring_V1_AutomaticLoginContents, receiverKey: Data,
        configurationRevision: UInt64, revision: UInt64) throws -> Agentkeyring_V1_SealedAutomaticLogin {
        let key = try P256.KeyAgreement.PublicKey(x963Representation: receiverKey)
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: .P256_SHA256_AES_GCM_256,
            info: Data("agentkeyring.login-copy.v1".utf8))
        let destination = keyID(receiverKey)
        var length = UInt32(destination.utf8.count).bigEndian
        var configurationRevision = configurationRevision.bigEndian
        var revision = revision.bigEndian
        var aad = withUnsafeBytes(of: &length) { Data($0) }
        aad.append(Data(destination.utf8))
        withUnsafeBytes(of: &configurationRevision) { aad.append(contentsOf: $0) }
        withUnsafeBytes(of: &revision) { aad.append(contentsOf: $0) }
        aad.append(Data(contents.loginID.utf8))
        var plaintext = try contents.serializedData()
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        var login = Agentkeyring_V1_SealedAutomaticLogin()
        login.loginID = contents.loginID
        login.sealed.encapsulatedKey = sender.encapsulatedKey
        login.sealed.ciphertext = try sender.seal(plaintext, authenticating: aad)
        login.sealed.receiverKeyID = destination
        return login
    }

    static func bundle(item: MirrorItem, leaseID: String, approvedAt: Int64, notAfter: Int64) throws -> Agentkeyring_V1_BundleContents {
        let resolver = CredentialResolver()
        let candidate = resolver.candidate(for: item)
        var contents = Agentkeyring_V1_BundleContents()
        contents.leaseID = leaseID
        contents.loginID = item.id.uuidString
        contents.sites = item.origins
        contents.notAfterUnixSeconds = notAfter
        if candidate.availableFields.contains(.username) { contents.username = try resolver.value(in: item, field: .username) }
        if candidate.availableFields.contains(.password) { contents.password = try resolver.value(in: item, field: .password) }
        if candidate.availableFields.contains(.totp) {
            let periods = item.credentials.compactMap { credential -> UInt16? in
                if case let .totp(_, period, _, _, _, _) = credential { period } else { nil }
            }
            guard periods.count == 1, let period = periods.first, period > 0 else { throw CredentialResolverError.invalidTOTP }
            var start = approvedAt / Int64(period) * Int64(period)
            while start < notAfter {
                var timed = Agentkeyring_V1_TimedCode()
                timed.validFromUnixSeconds = start
                timed.validUntilUnixSeconds = min(start + Int64(period), notAfter)
                timed.code = try resolver.value(in: item, field: .totp, now: Date(timeIntervalSince1970: Double(start)))
                contents.oneTimeCodes.append(timed)
                start += Int64(period)
            }
        }
        return contents
    }
}
