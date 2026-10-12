import AgentKeyringTestSupport
import Foundation
import Testing
@testable import AgentKeyringFeature

@MainActor
@Suite("Tamper-evident access rules")
struct SignedAccessRulesTests {
    @Test("A cold app request loads signed rules without opening a window")
    func signedColdStart() async throws {
        let fixture = SignedRulesFixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: fixture.store)
        let settingsName = "SignedRulesColdStart-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: settingsName))
        defer { settings.removePersistentDomain(forName: settingsName) }
        let controller = CredentialAccessController(store: fixture.store)
        let model = MirrorAppModel(store: EncryptedSnapshotStore(directoryURL: fixture.root.appendingPathComponent("vault"),
            keyProvider: StaticVaultKeyProvider(keyData: Data(repeating: 0x42, count: 32))),
            bridge: fixture.bridge, accessControl: controller, settings: settings)
        #expect(!controller.hasLoadedLoginList)
        let request = AgentBridgeRequest(action: .status)

        let socketResponse = try await sendTestAgentRequest(request, model: model, bridge: fixture.bridge)
        #expect(socketResponse.ok)
        #expect(!controller.needsConfirmation)
    }

    @Test("Agent requests and later file edits cannot replace the confirmation snapshot")
    func stableConfirmationSnapshot() async throws {
        let fixture = SignedRulesFixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: fixture.store, policies: [fixture.loginID: .block])
        try FileManager.default.moveItem(at: fixture.signatureURL, to: fixture.signatureURL.appendingPathExtension("held"))
        let snapshotBytes = try Data(contentsOf: fixture.fileURL)
        let controller = CredentialAccessController(store: fixture.store)
        #expect(!controller.canConfirmRules)
        await controller.refresh(fromMetadata: nil)
        #expect(!controller.canConfirmRules)
        await controller.confirmRules()
        #expect(try Data(contentsOf: fixture.fileURL) == snapshotBytes)
        await controller.refresh(from: fixture.generation)
        #expect(controller.canConfirmRules)
        #expect(controller.confirmationSummary == "0 allowed automatically, 1 blocked, 0 ask each time")
        let rows = controller.rows
        let attackerBytes = String(decoding: snapshotBytes, as: UTF8.self).replacingOccurrences(of: "block", with: "allowAutomatically")
        try Data(attackerBytes.utf8).write(to: fixture.fileURL)
        for _ in 0..<2 {
            do { try await controller.ensureRulesConfirmed(); Issue.record("Unconfirmed rules accepted") }
            catch let failure as AgentBridgeFailure { #expect(failure.code == .rulesNeedConfirmation) }
            await controller.refresh(from: fixture.generation)
            #expect(controller.rows == rows)
            #expect(controller.policy(for: fixture.loginID) == .block)
        }
        await controller.confirmRules()
        #expect(try Data(contentsOf: fixture.fileURL) == snapshotBytes)
        #expect(try await fixture.store.load()[fixture.loginID] == .block)
        #expect(fixture.signer.signingReason == "confirm your Agent Keyring access rules: 0 allowed automatically, 1 blocked, 0 ask each time. Your iPhone must be paired again.")
    }
    @Test("Restoring an older valid signed pair fails closed")
    func signedRollback() async throws {
        let fixture = SignedRulesFixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: fixture.store, policies: [fixture.loginID: .allowAutomatically])
        let oldBytes = try Data(contentsOf: fixture.fileURL)
        let oldSignature = try Data(contentsOf: fixture.signatureURL)
        try await fixture.store.save([fixture.loginID: .block])
        #expect(try await fixture.store.load()[fixture.loginID] == .block)
        try oldBytes.write(to: fixture.fileURL)
        try oldSignature.write(to: fixture.signatureURL)
        #expect(try fixture.signer.verify(oldSignature, for: oldBytes))
        await #expect(throws: AccessRulesConfirmationRequired.self) { try await fixture.store.load() }
    }

    @Test("Corrupt rules fail closed until an explicit reset is confirmed", arguments: [
        "invalid-json", "duplicate-record", "unknown-version",
    ], [true, false])
    func corruptRules(corruption: String, signed: Bool) async throws {
        let fixture = SignedRulesFixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: fixture.store, policies: [fixture.loginID: .allowAutomatically])
        let text: String = switch corruption {
        case "duplicate-record": """
            {"version":1,"records":[
            {"credentialID":"\(fixture.loginID)","policy":"block"},
            {"credentialID":"\(fixture.loginID)","policy":"allowAutomatically"}]}
            """
        case "unknown-version": "{\"version\":2,\"records\":[]}"
        default: "corrupt rules"
        }
        let bytes = Data(text.utf8)
        try bytes.write(to: fixture.fileURL)
        if signed { try FakeAccessRulesSigner().signature(for: bytes).write(to: fixture.signatureURL) }
        let controller = CredentialAccessController(store: fixture.store)
        await controller.refresh(from: fixture.generation)
        #expect(controller.needsConfirmation)
        #expect(controller.confirmationResetsUnreadableRules)
        #expect(controller.errorMessage == AccessRulesConfirmationRequired.message)
        #expect(controller.releaseDecision(for: fixture.loginID, field: .username) == .needsConfirmation)
        do {
            try await controller.ensureRulesConfirmed()
            Issue.record("Corrupt rules passed the release gate")
        } catch let failure as AgentBridgeFailure { #expect(failure.code == .rulesNeedConfirmation) }
        await controller.confirmRules()
        #expect(!controller.needsConfirmation)
        #expect(!controller.confirmationResetsUnreadableRules)
        #expect(try await fixture.store.load().isEmpty)
        #expect(controller.releaseDecision(for: fixture.loginID, field: .password) == .requestAuthorization)
    }

    @Test("Unsigned upgrades retain the rules for review and require confirmation", arguments: [
        CredentialAccessPolicy.ask, .allowAutomatically, .block,
    ])
    func unsignedUpgrade(policy: CredentialAccessPolicy) async throws {
        let fixture = SignedRulesFixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: fixture.store, policies: [fixture.loginID: policy])
        try FileManager.default.moveItem(at: fixture.signatureURL,
            to: fixture.signatureURL.appendingPathExtension("held"))
        let controller = CredentialAccessController(store: fixture.store)
        await controller.refresh(from: fixture.generation)
        #expect(controller.needsConfirmation)
        #expect(controller.rows.first?.policy == policy)
        #expect(controller.releaseDecision(for: fixture.loginID, field: .username) == .needsConfirmation)
        await controller.confirmRules()
        #expect(!controller.needsConfirmation)
        #expect(controller.policy(for: fixture.loginID) == policy)
        #expect(try await fixture.store.load()[fixture.loginID, default: .ask] == policy)
    }

    @Test("Acquire needs confirmation before accessing the mirror")
    func unsignedAppRequests() async throws {
        let fixture = SignedRulesFixture()
        defer { fixture.cleanUp() }
        let settingsName = "SignedRulesTests-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: settingsName))
        defer { settings.removePersistentDomain(forName: settingsName) }
        let model = MirrorAppModel(store: EncryptedSnapshotStore(directoryURL: fixture.root.appendingPathComponent("vault"),
            keyProvider: StaticVaultKeyProvider(keyData: Data(repeating: 0x42, count: 32))),
            bridge: fixture.bridge, accessControl: CredentialAccessController(store: fixture.store), settings: settings)
        let request = AgentBridgeRequest(action: .acquire, targetURL: "https://example.com", field: .password)

        let response = try await sendTestAgentRequest(request, model: model, bridge: fixture.bridge)
        #expect(!response.ok)
        #expect(response.error == .rulesNeedConfirmation)
        #expect(response.message == AccessRulesConfirmationRequired.message)
        #expect(response.mirror == nil)
    }

    @Test("A valid signature loads automatic rules")
    func validSignature() async throws {
        let fixture = SignedRulesFixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: fixture.store, policies: [fixture.loginID: .allowAutomatically])
        #expect(try await fixture.store.load() == [fixture.loginID: .allowAutomatically])
    }

    @Test("Missing files, edited bytes, missing signatures and missing keys fail closed", arguments: [
        "no-file", "edited", "no-signature", "no-key", "replaced-key",
    ])
    func failClosed(change: String) async throws {
        let fixture = SignedRulesFixture()
        defer { fixture.cleanUp() }
        if change != "no-file" { try await confirmInitialAccessRules(in: fixture.store, policies: [fixture.loginID: .allowAutomatically]) }
        let controller = CredentialAccessController(store: fixture.store)
        await controller.refresh(from: fixture.generation)
        if change == "edited" {
            var bytes = try Data(contentsOf: fixture.fileURL)
            bytes.append(0x20)
            try bytes.write(to: fixture.fileURL)
        } else if change == "no-signature" {
            try FileManager.default.moveItem(at: fixture.signatureURL,
                to: fixture.signatureURL.appendingPathExtension("held"))
        }
        let activeController: CredentialAccessController
        if change == "no-key" || change == "replaced-key" {
            let signer = FakeAccessRulesSigner(key: change == "replaced-key" ? Data("different key".utf8) : Data("test rules key".utf8),
                keyIsMissing: change == "no-key")
            activeController = CredentialAccessController(store: CredentialAccessPolicyStore(fileURL: fixture.fileURL, signer: signer))
        } else { activeController = controller }
        do {
            try await activeController.ensureRulesConfirmed()
            Issue.record("Untrusted rules were accepted")
        } catch let failure as AgentBridgeFailure {
            #expect(failure.code == .rulesNeedConfirmation)
            #expect(failure.message == AccessRulesConfirmationRequired.message)
        }
        await activeController.refresh(from: fixture.generation)
        #expect(activeController.needsConfirmation)
        for field in [AgentCredentialField.username, .password, .totp] {
            #expect(activeController.releaseDecision(for: fixture.loginID, field: field) == .needsConfirmation)
        }
        let request = AgentBridgeRequest(action: .acquire, targetURL: "https://example.com", field: .password)

        let grants = CredentialApprovalGrants()
        grants.approve(fixture.loginID, action: .acquire, requesterIdentity: syntheticVerifiedRequester.verifiedIdentity!, site: "example.com", account: "synthetic@example.com")
        let processor = AgentCredentialReleaseProcessor(accessControl: activeController, grants: grants)
        do {
            _ = try await processor.release(request: request, requester: syntheticVerifiedRequester, generation: fixture.generation,
                authorize: { _, _ in Issue.record("Untrusted rules started an approval") })
            Issue.record("Untrusted rules released a credential")
        } catch let failure as AgentBridgeFailure { #expect(failure.code == .rulesNeedConfirmation) }
        #expect(throws: CredentialTransferError.unavailable) { _ = try CredentialTransfer.read(requestID: request.id) }
    }

    @Test("An attacker's public key beside the file cannot authenticate replacement rules")
    func publicKeyOnDiskIsIgnored() async throws {
        let fixture = SignedRulesFixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: fixture.store, policies: [fixture.loginID: .block])
        let attacker = FakeAccessRulesSigner(key: Data("attacker key".utf8))
        try attacker.key.write(to: fixture.fileURL.appendingPathExtension("public-key"))
        let attackerStore = CredentialAccessPolicyStore(fileURL: fixture.fileURL, signer: attacker)
        try await confirmInitialAccessRules(in: attackerStore, policies: [fixture.loginID: .allowAutomatically])
        await #expect(throws: AccessRulesConfirmationRequired.self) { try await fixture.store.load() }
    }

    @Test("Confirming shows and re-signs the altered rules with the app's signer")
    func confirmationResigns() async throws {
        let fixture = SignedRulesFixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: fixture.store, policies: [fixture.loginID: .block])
        let changed = String(decoding: try Data(contentsOf: fixture.fileURL), as: UTF8.self)
            .replacingOccurrences(of: "block", with: "allowAutomatically")
        try Data(changed.utf8).write(to: fixture.fileURL)
        let controller = CredentialAccessController(store: fixture.store)
        await controller.refresh(from: fixture.generation)
        #expect(controller.needsConfirmation)
        #expect(controller.rows.first?.policy == .allowAutomatically)
        await controller.confirmRules()
        #expect(!controller.needsConfirmation)
        #expect(try await fixture.store.load() == [fixture.loginID: .allowAutomatically])
    }

    @Test("Editing rules while an approval is open prevents release")
    func editedDuringApproval() async throws {
        let fixture = SignedRulesFixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: fixture.store)
        let controller = CredentialAccessController(store: fixture.store)
        let request = AgentBridgeRequest(action: .acquire, targetURL: "https://example.com", field: .password)

        let processor = AgentCredentialReleaseProcessor(accessControl: controller,
            approvals: CredentialApprovalCoordinator(lockState: SignedRulesUnlockedSession()))
        do {
            _ = try await processor.release(request: request, requester: syntheticVerifiedRequester, generation: fixture.generation, authorize: { _, _ in
                var bytes = try Data(contentsOf: fixture.fileURL)
                bytes.append(0x20)
                try bytes.write(to: fixture.fileURL)
            })
            Issue.record("Rules changed during approval but a credential was released")
        } catch let failure as AgentBridgeFailure { #expect(failure.code == .rulesNeedConfirmation) }
        #expect(throws: CredentialTransferError.unavailable) { _ = try CredentialTransfer.read(requestID: request.id) }
    }
}

private struct SignedRulesUnlockedSession: CredentialSessionLockState {
    var isLocked: Bool { false }
}

struct SignedRulesFixture {
    let signer = FakeAccessRulesSigner()
    let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(UUID().uuidString)
    let loginID = UUID()
    var fileURL: URL { root.appendingPathComponent("policies.json") }
    var signatureURL: URL { fileURL.appendingPathExtension("signature") }
    var store: CredentialAccessPolicyStore { CredentialAccessPolicyStore(fileURL: fileURL, signer: signer) }
    var bridge: AgentBridgeDirectory { AgentBridgeDirectory(rootURL: root.appendingPathComponent("bridge")) }
    var generation: MirrorGeneration {
        MirrorGeneration(id: UUID(), previousGenerationID: nil, createdAt: Date(), sourceExportedAt: Date(),
            scope: .full, exporterIdentifier: "fixture", exporterDisplayName: "Fixture", items: [
                MirrorItem(id: loginID, sourceIdentity: MirrorSourceIdentity(exporterIdentifier: "fixture", accountID: Data(), itemID: Data()),
                    title: "Synthetic login", origins: ["https://example.com"],
                    credentials: [.password(userName: "synthetic", password: "synthetic-password")])
            ], skippedCredentialCount: 0)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
