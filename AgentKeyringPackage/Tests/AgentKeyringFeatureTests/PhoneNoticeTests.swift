// Written by AI on 2026.11.20 by model Claude Opus 5.5.
// The iPhone's notification names a practice notice with the practice words
// (on 20 Nov it showed the fallback "An agent wants to use a password."), and
// still refuses a computer's request that its computer did not sign.

@testable import AgentKeyringPhoneApprover
import AgentKeyringApprovalUI
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import Testing

@Suite("iPhone notification words")
struct PhoneNoticeTests {
    func work(_ build: (inout KeyringRequest) -> Void) throws -> Agentkeyring_V2_Work {
        var request = KeyringRequest()
        request.domain = "agentkeyring.request.v2"; request.requestID = "r1"
        request.answerByUnixSeconds = Int64(Date().timeIntervalSince1970) + 600
        build(&request)
        var work = Agentkeyring_V2_Work()
        work.request = try request.serializedData()
        return work
    }

    @Test("A practice notice is named with the practice words")
    func practiceNotice() throws {
        let relay = P256.Signing.PrivateKey()
        var members = Members()
        members.relayTlsPublicKey = relay.publicKey.derRepresentation
        var practice = try work { $0.forDeviceKeyID = "phone" }
        practice.requestSignature = try relay.signature(for: practice.request).derRepresentation
        let named = try PhoneKeyring.named(practice, members: members, catalogue: nil, keyID: "phone")
        #expect(named.request.login.site == PhoneCopy.practiceSite)
        #expect(named.request.agentReason == PhoneCopy.practiceReason)
    }

    @Test("A computer's request without its signature is not named")
    func unsignedRequest() throws {
        var machine = Agentkeyring_V2_Machine()
        machine.machineID = "mini"; machine.tlsPublicKey = P256.Signing.PrivateKey().publicKey.derRepresentation
        var members = Members()
        members.machines = [machine]
        #expect(throws: PhoneKeyring.Unnamed.self) {
            try PhoneKeyring.named(work { $0.machineID = "mini"; $0.loginID = "example" }, members: members, catalogue: nil, keyID: "phone")
        }
    }

    /// On 20 Nov the self-test reported "test request: ended ended": the approval's own end overwrote the approval.
    @Test("An approved practice stays approved when its approval ends a minute later")
    func practiceApprovalLatches() {
        #expect(PhoneKeyring.latched(.approved, .ended) == .approved)
        #expect(PhoneKeyring.latched(nil, .denied) == .denied)
        #expect(PhoneKeyring.latched(.denied, .approved) == .approved)
    }

    /// On 20 Nov the relay recorded "approved by iPhone" and the app said "Your answer wasn't sent":
    /// the notification's Approve and the app's both ran, and the second was refused.
    @Test("A second Approve or Deny for a request this iPhone already answered is not an error")
    @MainActor func answeringTwice() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var answered = try work { $0.machineID = "mini"; $0.loginID = "example" }
        answered.outcome.state = .approved
        var saved = PhoneSavedState()
        saved.deviceKeyID = "phone"
        saved.mac = MacDoor(host: "100.100.1.1", port: 17446, key: Data([1]), name: "MacBook Pro")
        saved.work = ["r1": try answered.serializedData()]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(saved).write(to: directory.appending(path: "phone-v2.plist"))
        let backend = PhoneKeyring(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: NoKeys(),
                                   identity: { throw CancellationError() })
        try await backend.approve("r1", reusingUnlock: false)
        try await backend.deny("r1", reply: nil)
    }
}

/// His iPhone holds state saved by the build before this one; a first-run step that build had and this one has not
/// must read as nil, never wipe the rest (the join, the lists, the settings).
@Test("Saved state from an earlier build with a step this build dropped still reads")
func earlierBuildsFirstRunStillReads() throws {
    var saved = PhoneSavedState()
    saved.deviceKeyID = "phone"
    saved.firstRun = .finished
    var plist = try PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(saved), format: nil) as! [String: Any]
    #expect(try PropertyListDecoder().decode(PhoneSavedState.self, from: PropertyListEncoder().encode(saved)).firstRun == .finished)
    plist["firstRun"] = ["ready": [String: Any]()]
    let old = try PropertyListDecoder().decode(PhoneSavedState.self, from: PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0))
    #expect(old.deviceKeyID == "phone")
    #expect(old.firstRun == nil)
    saved.firstRun = nil
    #expect(try PropertyListDecoder().decode(PhoneSavedState.self, from: PropertyListEncoder().encode(saved)).firstRun == nil)
}

/// Keys that are never reached: an answered request needs none.
@MainActor struct NoKeys: PhoneDeviceKeys {
    struct Unused: Error {}
    func signingPublicKey() throws -> Data { throw Unused() }
    func openingPublicKey() throws -> Data { throw Unused() }
    func replyPublicKey() throws -> Data { throw Unused() }
    func noticePublicKey() throws -> Data { throw Unused() }
    func authorize(_ context: LAContext, reason: String) async throws { throw Unused() }
    func sign(_ bytes: Data, context: LAContext) throws -> Data { throw Unused() }
    func open(_ sealed: SealedLogin, context: LAContext) throws -> LoginSecret { throw Unused() }
    func signReply(_ bytes: Data) throws -> Data { throw Unused() }
    func openNotice(_ notice: Agentkeyring_V2_Notice, deviceKeyID: String) throws -> Agentkeyring_V2_Work { throw Unused() }
}
