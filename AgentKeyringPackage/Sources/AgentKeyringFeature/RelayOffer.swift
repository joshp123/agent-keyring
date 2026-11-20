// Written by AI on 2026.11.20 by model claude opus 5.5.
//
// The computer that stays on announces itself, and the Mac connects with
// nothing typed. Our app on the Mac mini finds the relay running on that
// same computer, asks it for its one-time secret (the relay gives it only to
// a caller on its own address, and only while it has no members), and leaves
// the relay's address, key and secret in iCloud Keychain. A Mac on the same
// Apple Account reads it and offers "Connect to Mac mini?"; its first members
// list carries proof of the secret, so nobody else on the network can take
// the empty relay first.

import AgentKeyringProtocol
import AgentKeyringRelaySupport
import AgentKeyringSealing
import Darwin
import Foundation
import LocalAuthentication
import Security

@MainActor
extension MacDevice {
    /// The port the relay listens on, as the Mac mini's Nix service sets it.
    static let relayPort: UInt16 = 17445

    private static var offerItem: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: true,
         kSecAttrAccessGroup as String: Bundle.main.object(forInfoDictionaryKey: "AgentKeyringSharedKeychainGroup") as? String ?? "",
         kSecAttrService as String: "com.joshpalmer.AgentKeyring.relay-offer", kSecAttrAccount as String: "offer"]
    }

    /// This Mac runs the relay, which is still empty: it leaves the offer in
    /// iCloud Keychain and returns true. Once the relay has members, or if
    /// there is none here, the offer is taken away.
    @discardableResult
    func announceIfRelayHere() async -> Bool {
        guard let address = Self.tailnetAddress(), let endpoint = try? RelayEndpoint(host: address, port: Self.relayPort) else { return false }
        var request = Agentkeyring_V2_RelayRequest()
        request.method = .setupOffer(Agentkeyring_V2_Empty())
        var spki = Data()
        let answer = try? await KeyringRelay(endpoint: endpoint, identity: keys.tls, pin: nil).call(request) { spki = $0 }
        guard case let .setupOffer(offer)? = answer?.result, offer.relayTlsPublicKey == spki else {
            if answer != nil || !spki.isEmpty { SecItemDelete(Self.offerItem as CFDictionary) } // Set up already.
            return !spki.isEmpty
        }
        var announced = Agentkeyring_V2_RelayOffer()
        announced.relayHost = address
        announced.relayPort = UInt32(Self.relayPort)
        announced.relayTlsPublicKey = offer.relayTlsPublicKey
        announced.secret = offer.secret
        announced.label = Host.current().localizedName ?? "Mac"
        guard let value = try? announced.serializedData() else { return true }
        SecItemDelete(Self.offerItem as CFDictionary)
        var item = Self.offerItem
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        DiagnosticLog.record("relay", status == errSecSuccess ? "offered" : "offer-failed", ["host": address, "status": "\(status)"])
        return true
    }

    /// The offer a computer of his left in iCloud Keychain, if any.
    public func relayOffer() -> Agentkeyring_V2_RelayOffer? {
        var query = Self.offerItem
        query[kSecReturnData as String] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let bytes = found as? Data else { return nil }
        return try? Agentkeyring_V2_RelayOffer(serializedBytes: bytes)
    }

    /// "Connect to Mac mini?": the relay in the offer, after his Touch ID.
    public func connect(to offer: Agentkeyring_V2_RelayOffer, context: LAContext, onAuthenticated: @MainActor () -> Void) async throws {
        let endpoint = try RelayEndpoint(host: offer.relayHost, port: UInt16(clamping: offer.relayPort))
        try await connect(to: endpoint, context: context, expecting: offer.relayTlsPublicKey,
            proof: Sealing.setupProof(secret: offer.secret, relaySPKI: offer.relayTlsPublicKey, firstDeviceKeyID: keys.deviceKeyID),
            onAuthenticated: onAuthenticated)
        SecItemDelete(Self.offerItem as CFDictionary)
    }

    /// This Mac's Tailscale address (100.64.0.0/10), where a relay here listens.
    static func tailnetAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let socket = entry.pointee.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET) else { continue }
            let address = socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if address & 0xFFC0_0000 == 0x6440_0000 { // 100.64.0.0/10
                return "\(address >> 24).\((address >> 16) & 0xFF).\((address >> 8) & 0xFF).\(address & 0xFF)"
            }
        }
        return nil
    }
}
