// Written by AI on 2026.11.26 by model gemini-4-neon.
//
// Opens a push notice using the iPhone's Secure Enclave notice key from the
// shared keychain group. Runs inside the notification service extension while
// the device is locked (AfterFirstUnlock), with no iCloud or import dependencies.

#if os(iOS)
import AgentKeyringProtocol
import CryptoKit
import Foundation
import Security

public struct PhoneNoticeOpener: Sendable {
    private let service = "com.joshpalmer.AgentKeyring.Phone.keys.v2"
    private let accessGroup: String?

    public init(accessGroup: String?) { self.accessGroup = accessGroup }

    public func openNotice(_ notice: Agentkeyring_V2_Notice, deviceKeyID: String) throws -> Agentkeyring_V2_SignedRequestEnvelope {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "notice",
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data)
        return try CredentialSealing.openNotice(notice, deviceKeyID: deviceKeyID, with: key)
    }
}
#endif
