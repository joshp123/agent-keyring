import CryptoKit
import AgentKeyringTestSupport
import Foundation
import Synchronization
import Testing
@testable import AgentKeyringFeature

@Suite("Paired-device approval verification")
struct ApprovalDecisionVerifierTests {
    @Test("Every decision and action verifies once with a real paired P-256 key",
        arguments: ApprovalChoice.allCases, [ApprovalAction.fill, .acquire])
    func validDecision(choice: ApprovalChoice, action: ApprovalAction) async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.pair()
        let request = try fixture.request(action: action)
        let verifier = fixture.verifier()
        try await verifier.register(request)
        let decision = try fixture.decision(request.signedFields, choice: choice)
        #expect(try await verifier.verify(decision) == choice)
        await #expect(throws: ApprovalDecisionRefusal.replayed) { try await verifier.verify(decision) }
        await #expect(throws: ApprovalDecisionRefusal.replayed) { try await verifier.register(request) }
    }

    @Test("Signing any tampered request field fails against the Mac's retained request",
        arguments: ["agent-label", "site", "account", "field", "action", "one-time-value", "expiry"])
    func tamperedField(field: String) async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.pair()
        let request = try fixture.request()
        let verifier = fixture.verifier()
        try await verifier.register(request)
        let original = request.signedFields
        let changed = ApprovalSignedFields(requestID: original.requestID,
            agentDisplayLabel: field == "agent-label" ? "Other agent" : original.agentDisplayLabel,
            site: field == "site" ? "https://other.example" : original.site,
            account: field == "account" ? "other" : original.account,
            field: field == "field" ? .username : original.field,
            action: field == "action" ? .acquire : original.action,
            oneTimeValue: field == "one-time-value" ? Data(repeating: 0, count: 32) : original.oneTimeValue,
            expiresAt: field == "expiry" ? original.expiresAt + 1 : original.expiresAt)
        await #expect(throws: ApprovalDecisionRefusal.invalidSignature) {
            try await verifier.verify(fixture.decision(changed))
        }
        // Refusals do not consume the authentic request.
        #expect(try await verifier.verify(fixture.decision(original)) == .approve)
    }

    @Test("A wrong signing key cannot claim the paired device's identity")
    func wrongKey() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.pair()
        let request = try fixture.request()
        let verifier = fixture.verifier()
        try await verifier.register(request)
        let attacker = P256.Signing.PrivateKey()
        let decision = ApprovalDecision(requestID: request.id, choice: .approve,
            devicePublicKey: fixture.phoneKey.publicKey.x963Representation,
            signature: try attacker.signature(for: request.signedFields.canonicalBytes(for: .approve)).derRepresentation)
        await #expect(throws: ApprovalDecisionRefusal.invalidSignature) { try await verifier.verify(decision) }
    }

    @Test("The decision itself is signed; changing approve to block is rejected")
    func changedChoice() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.pair()
        let request = try fixture.request()
        let verifier = fixture.verifier()
        try await verifier.register(request)
        let original = try fixture.decision(request.signedFields)
        let changed = ApprovalDecision(requestID: original.requestID, choice: .blockThisLogin,
            devicePublicKey: original.devicePublicKey, signature: original.signature)
        await #expect(throws: ApprovalDecisionRefusal.invalidSignature) { try await verifier.verify(changed) }
    }

    @Test("Expiry is checked at the deadline, after asynchronous key loading")
    func expiredDecision() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.pair()
        let request = try fixture.request()
        let clock = TestApprovalClock(PhoneApprovalFixture.now)
        let provider = ExpiringPairedDeviceProvider(store: fixture.store, clock: clock,
            deadline: Date(timeIntervalSince1970: TimeInterval(request.expiresAt)))
        let verifier = ApprovalDecisionVerifier(pairedDevices: provider, now: { clock.now })
        try await verifier.register(request)
        await #expect(throws: ApprovalDecisionRefusal.expired) {
            try await verifier.verify(fixture.decision(request.signedFields))
        }
    }

    @Test("A decision for another request cannot consume a pending request")
    func differentRequest() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.pair()
        let request = try fixture.request()
        let verifier = fixture.verifier()
        try await verifier.register(request)
        await #expect(throws: ApprovalDecisionRefusal.unknownRequest) {
            try await verifier.verify(fixture.decision(fixture.request().signedFields))
        }
        #expect(try await verifier.verify(fixture.decision(request.signedFields)) == .approve)
    }

    @Test("Concurrent decisions have exactly one winner")
    func concurrentReplay() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.pair()
        let request = try fixture.request()
        let verifier = fixture.verifier()
        try await verifier.register(request)
        let decision = try fixture.decision(request.signedFields)
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { _ = try await verifier.verify(decision); return true }
                    catch { #expect(error as? ApprovalDecisionRefusal == .replayed); return false }
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(outcomes.filter { $0 }.count == 1)
    }

    @Test("Receipts survive other registrations, and a fresh verifier rejects old decisions")
    func receiptLifetime() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.pair()
        let clock = TestApprovalClock(PhoneApprovalFixture.now)
        let verifier = ApprovalDecisionVerifier(pairedDevices: fixture.store, now: { clock.now })
        let request = try fixture.request()
        let decision = try fixture.decision(request.signedFields)
        try await verifier.register(request)
        #expect(try await verifier.verify(decision) == .approve)
        clock.set(Date(timeIntervalSince1970: TimeInterval(request.expiresAt - 1)))
        try await verifier.register(fixture.request())
        await #expect(throws: ApprovalDecisionRefusal.replayed) { try await verifier.verify(decision) }
        await #expect(throws: ApprovalDecisionRefusal.unknownRequest) { try await fixture.verifier().verify(decision) }
    }

    @Test("An unpaired or removed device is rejected even with a valid signature")
    func unpairedDevice() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: fixture.store)
        let request = try fixture.request()
        let verifier = fixture.verifier()
        try await verifier.register(request)
        let decision = try fixture.decision(request.signedFields)
        await #expect(throws: ApprovalDecisionRefusal.unpairedDevice) { try await verifier.verify(decision) }
        try await fixture.store.addPairedDevice(fixture.device)
        try await fixture.store.removePairedDevice(publicKey: fixture.device.publicKey)
        await #expect(throws: ApprovalDecisionRefusal.unpairedDevice) { try await verifier.verify(decision) }
    }

    @Test("Expired pending requests are purged before checking duplicate registration")
    func expiredRegistration() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        let request = try fixture.request()
        let clock = TestApprovalClock(PhoneApprovalFixture.now)
        let verifier = ApprovalDecisionVerifier(pairedDevices: fixture.store, now: { clock.now })
        try await verifier.register(request)
        await #expect(throws: ApprovalDecisionRefusal.requestAlreadyRegistered) { try await verifier.register(request) }
        clock.set(Date(timeIntervalSince1970: TimeInterval(request.expiresAt)))
        await #expect(throws: ApprovalDecisionRefusal.expired) { try await verifier.register(request) }
    }
}

struct PhoneApprovalFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    let root: URL
    let signer: CryptoKitRulesTestSigner
    let phoneKey = P256.Signing.PrivateKey()
    let store: CredentialAccessPolicyStore
    var fileURL: URL { root.appendingPathComponent("policies.json") }
    var signatureURL: URL { fileURL.appendingPathExtension("signature") }
    var device: PairedApprovalDevice {
        PairedApprovalDevice(publicKey: phoneKey.publicKey, name: "Test iPhone", pairedAt: Self.now)
    }

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        signer = CryptoKitRulesTestSigner()
        store = CredentialAccessPolicyStore(fileURL: root.appendingPathComponent("policies.json"), signer: signer)
    }

    func pair() async throws {
        try await confirmInitialAccessRules(in: store)
        try await store.addPairedDevice(device)
    }

    func request(action: ApprovalAction = .fill) throws -> ApprovalRequest {
        try ApprovalRequest(agentDisplayLabel: "Test agent", site: "https://example.com", account: "synthetic",
            field: .password, action: action, createdAt: Self.now)
    }

    func verifier() -> ApprovalDecisionVerifier {
        ApprovalDecisionVerifier(pairedDevices: store, now: { Self.now })
    }

    func decision(_ fields: ApprovalSignedFields, choice: ApprovalChoice = .approve) throws -> ApprovalDecision {
        ApprovalDecision(requestID: fields.requestID, choice: choice, devicePublicKey: phoneKey.publicKey.x963Representation,
            signature: try phoneKey.signature(for: fields.canonicalBytes(for: choice)).derRepresentation)
    }

    func cleanUp() { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
}

final class CryptoKitRulesTestSigner: AccessRulesSigning {
    private let key = P256.Signing.PrivateKey()
    private let state = Mutex((hash: Optional<Data>.none, reason: Optional<String>.none, refusesSigning: false))
    var signingReason: String? { state.withLock { $0.reason } }
    func refuseSigning() { state.withLock { $0.refusesSigning = true } }

    func sign(_ bytes: Data, reason: String) async throws -> Data {
        try state.withLock {
            if $0.refusesSigning { throw CocoaError(.userCancelled) }
            $0.hash = Data(SHA256.hash(data: bytes))
            $0.reason = reason
        }
        return try key.signature(for: bytes).derRepresentation
    }

    func verify(_ signature: Data, for bytes: Data) throws -> Bool {
        key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: signature), for: bytes)
    }

    func signedBytesHash() throws -> Data? { state.withLock { $0.hash } }
}

private struct ExpiringPairedDeviceProvider: PairedDevicePublicKeyProviding {
    let store: CredentialAccessPolicyStore
    let clock: TestApprovalClock
    let deadline: Date

    func pairedDevicePublicKeys() async throws -> [Data] {
        let keys = try await store.pairedDevicePublicKeys()
        clock.set(deadline)
        return keys
    }
}

private final class TestApprovalClock: Sendable {
    private let value: Mutex<Date>
    init(_ date: Date) { value = Mutex(date) }
    var now: Date { value.withLock { $0 } }
    func set(_ date: Date) { value.withLock { $0 = date } }
}
