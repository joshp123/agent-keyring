// Written by AI on 2026.11.23 by model gemini-4-neon.
import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import AgentKeyringEngine
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import Testing

@Suite("Blind push relay & version check")
struct PushRelayAndVersionTests {
    @Test("VersionCheck anonymous ID is stable, non-reversible, and shared across devices on the same iCloud account")
    func stableAnonymousID() {
        let mac = VersionCheck.anonymousID(accountSeed: "_icloud_user_abc", localSeed: "mac-uuid-1")
        let phone = VersionCheck.anonymousID(accountSeed: "_icloud_user_abc", localSeed: "phone-uuid-2")
        let other = VersionCheck.anonymousID(accountSeed: "_icloud_user_xyz", localSeed: "mac-uuid-1")
        let localOnly = VersionCheck.anonymousID(accountSeed: nil, localSeed: "mac-uuid-1")

        #expect(mac.count == 16)
        #expect(mac == phone)
        #expect(mac != other)
        #expect(mac != localOnly)
        #expect(!mac.contains("icloud"))
    }

    @Test("VersionCheck caches the hashed account ID and reuses it while iCloud is unavailable")
    func cachesAccountHash() throws {
        let suite = "agent-keyring-version-check-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = VersionCheck.resolvedAnonymousID(accountSeed: "_icloud_user_123", defaults: defaults)
        let offline = VersionCheck.resolvedAnonymousID(accountSeed: nil, defaults: defaults)
        #expect(first == offline)
        #expect(first == VersionCheck.anonymousID(accountSeed: "_icloud_user_123", localSeed: ""))

    }

    @Test("Outcome pushes to iPhone and Apple Watch use priority-10 passive collapse alerts while Mac stays background")
    func outcomePushUsesPassiveAlertForMobileAndBackgroundForMac() throws {
        let notice = Agentkeyring_V2_Notice()

        #expect(PushPayload.usesAlertTransport(waiting: true, for: .iphone))
        #expect(PushPayload.usesAlertTransport(waiting: false, for: .iphone))
        #expect(PushPayload.usesAlertTransport(waiting: true, for: .watch))
        #expect(PushPayload.usesAlertTransport(waiting: false, for: .watch))
        #expect(!PushPayload.usesAlertTransport(waiting: true, for: .mac))
        #expect(!PushPayload.usesAlertTransport(waiting: false, for: .mac))

        func decodeAPS(_ data: Data) throws -> [String: Any] {
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(root["aps"] as? [String: Any])
        }

        let iphoneOutcome = try decodeAPS(PushPayload.pushRequest(id: "req-42", notice: notice, waiting: false, for: .iphone))
        #expect(iphoneOutcome["interruption-level"] as? String == "passive")
        #expect(iphoneOutcome["mutable-content"] as? Int == 1)
        #expect(iphoneOutcome["content-available"] as? Int == 1)
        #expect(iphoneOutcome["alert"] != nil)
        #expect(iphoneOutcome["sound"] == nil)
        #expect(iphoneOutcome["category"] == nil)

        let watchOutcome = try decodeAPS(PushPayload.pushRequest(id: "req-42", notice: notice, waiting: false, for: .watch))
        #expect(watchOutcome["interruption-level"] as? String == "passive")
        #expect(watchOutcome["mutable-content"] as? Int == 1)
        #expect(watchOutcome["content-available"] as? Int == 1)
        #expect(watchOutcome["category"] == nil)

        let macOutcome = try decodeAPS(PushPayload.pushRequest(id: "req-42", notice: notice, waiting: false, for: .mac))
        #expect(macOutcome["alert"] == nil)
        #expect(macOutcome["content-available"] as? Int == 1)

        // PhoneNotification.ended must recognise both passive collapse alerts and silent outcome pushes,
        // while never mistaking a waiting time-sensitive request push for an ended request.
        let iphoneOutcomeRoot = try #require(
            JSONSerialization.jsonObject(with: PushPayload.pushRequest(id: "req-42", notice: notice, waiting: false, for: .iphone)) as? [AnyHashable: Any]
        )
        let macOutcomeRoot = try #require(
            JSONSerialization.jsonObject(with: PushPayload.pushRequest(id: "req-42", notice: notice, waiting: false, for: .mac)) as? [AnyHashable: Any]
        )
        let iphoneWaitingRoot = try #require(
            JSONSerialization.jsonObject(with: PushPayload.pushRequest(id: "req-42", notice: notice, waiting: true, for: .iphone)) as? [AnyHashable: Any]
        )
        #expect(PhoneNotification.ended(iphoneOutcomeRoot) == "req-42")
        #expect(PhoneNotification.ended(macOutcomeRoot) == "req-42")
        #expect(PhoneNotification.ended(iphoneWaitingRoot) == nil)
    }

    @Test("Waiting request pushes carry the per-device fallback category for iPhone and Watch, and none for Mac or an unknown device")
    func requestPushCarriesPerDeviceFallbackCategory() throws {
        func aps(_ data: Data) throws -> [String: Any] {
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(json["aps"] as? [String: Any])
        }
        let phone = try aps(PushPayload.pushRequest(id: "req-1", notice: Agentkeyring_V2_Notice(), waiting: true, for: .iphone))
        #expect(phone["category"] as? String == "REQUEST")
        #expect(phone["mutable-content"] as? Int == 1)

        let watch = try aps(PushPayload.pushRequest(id: "req-1", notice: Agentkeyring_V2_Notice(), waiting: true, for: .watch))
        #expect(watch["category"] as? String == "WATCH_REQUEST")
        #expect(watch["mutable-content"] as? Int == 1)

        let mac = try aps(PushPayload.pushRequest(id: "req-1", notice: Agentkeyring_V2_Notice(), waiting: true, for: .mac))
        #expect(mac["category"] == nil)

        let unspecified = try aps(PushPayload.pushRequest(id: "req-1", notice: Agentkeyring_V2_Notice(), waiting: true))
        #expect(unspecified["category"] == nil)
    }
}
