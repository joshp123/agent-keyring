// Written by AI on 2026.11.23 by model claude opus 5.5.
//
// Blocking deletes a password everywhere, and only once the change is saved;
// copying it from Passwords again after unblocking is a change the other
// devices are asked to take.

import AgentKeyringProtocol
import Foundation
import LocalAuthentication
import Testing
@testable import AgentKeyringApprovalUI
@testable import AgentKeyringEngine
import AgentKeyringApprovalCore

@MainActor
@Suite("Blocked passwords")
struct BlockedLifecycleTests {
    private func controller() async -> (CredentialAccessController, UUID) {
        var saved: Data?
        let controller = CredentialAccessController(store: LoginRuleStore(read: { saved }, write: { saved = $0 }))
        let id = UUID()
        let metadata = MacVaultMetadata(safeStatus: ImportedVaultStatus(snapshotID: UUID(), importedAt: .now, sourceExportedAt: .now, scope: .full,
            credentialItemCount: 1, skippedCredentialCount: 0), candidates: [CredentialCandidate(id: id, title: "bank.example", username: "you",
            origins: ["https://bank.example"], availableFields: [.username, .password])])
        await controller.refresh(fromMetadata: metadata)
        return (controller, id)
    }

    @Test("A Block that fails to publish deletes nothing; one that saves deletes the password after saving")
    func deletesOnlyOnceSaved() async {
        let (failing, id) = await controller()
        var deleted: [UUID] = []
        failing.beforeSave = { _, _, _ in throw CancellationError() }
        failing.afterSave = { _, new in deleted += new.filter { $0.value == .blocked }.keys }
        await failing.setRule(.blocked, for: [id], context: LAContext())
        #expect(failing.rule(for: id) == .ask)
        #expect(deleted.isEmpty)

        let (saving, savedID) = await controller()
        saving.afterSave = { _, new in
            #expect(saving.rule(for: savedID) == .blocked)
            deleted += new.filter { $0.value == .blocked }.keys
        }
        await saving.setRule(.blocked, for: [savedID], context: LAContext())
        #expect(deleted == [savedID])
    }

    @Test("Copied again after unblocking, or a rule the iPhone changed, counts as a change to send; the same list does not")
    func restoredCountsAsUnsent() {
        let id = UUID()
        var sent = Agentkeyring_V2_Login()
        sent.loginID = id.uuidString
        sent.rule = .ask
        sent.version = 0 // Unblocked; deleted when blocked.
        let restored = CredentialCandidate(id: id, title: "bank.example", username: "you", origins: [], availableFields: [.password])
        let stillDeleted = CredentialCandidate(id: id, title: "bank.example", username: "you", origins: [], availableFields: [.password], secretDeleted: true)
        #expect(MacKeyringEngine.differs(sent: [sent], here: [restored], rule: { _ in .ask }) == [id.uuidString])
        #expect(MacKeyringEngine.differs(sent: [sent], here: [stillDeleted], rule: { _ in .ask }).isEmpty)
        #expect(MacKeyringEngine.differs(sent: [sent], here: [stillDeleted], rule: { _ in .blocked }) == [id.uuidString])
    }

    @Test("Unblocking flags that the password must be copied again; blocking again does not")
    @MainActor func unblockSentence() {
        let bank = LoginRow(id: UUID(), site: "bank.example", account: "you", rule: .blocked, secretDeleted: true)
        let mail = LoginRow(id: UUID(), site: "mail.example", account: "you", rule: .ask, secretDeleted: true)
        let model = MacMainModel(backend: SandboxMainBackend(SandboxWorld()), initial: MainSnapshot(logins: [bank, mail], importedAt: nil))
        model.beginEditingRules()
        model.toggleEditSelection(bank.id)
        model.requestRuleChange(.ask)
        #expect(model.ruleConfirmation?.plan.needsReimportCount == 1)
        model.cancelRuleChange()
        model.toggleEditSelection(mail.id)
        model.requestRuleChange(.automatic)
        #expect(model.ruleConfirmation?.plan.needsReimportCount == 2)
        model.cancelRuleChange()
        model.selectedForEdit = [mail.id]
        model.requestRuleChange(.blocked)
        #expect(model.ruleConfirmation?.plan.needsReimportCount == 0)
        #expect(model.ruleConfirmation?.plan.willDeleteSecretsCount == 0)
    }

    @Test("A rule change ends the grants the lease store would end, and picking only unchanged logins is no change")
    func ruleChangePlanEndsTheRightGrants() {
        typealias Plan = RuleChangePlan<String>
        let picked = [
            RuleChangePlanLogin<String>(id: "auto", rule: .automatic, holdsSecret: true, activeLeases: 3, automaticLeases: 2),
            RuleChangePlanLogin<String>(id: "ask", rule: .ask, holdsSecret: true, activeLeases: 1),
            RuleChangePlanLogin<String>(id: "gone", rule: .ask, holdsSecret: false),
        ]
        let block = Plan(target: .blocked, selected: picked)
        #expect(block.affectedLoginIDs == ["auto", "ask", "gone"])
        #expect(block.willDeleteSecretsCount == 2)
        #expect(block.willRevokeLeasesCount == 4)
        #expect(block.needsReimportCount == 0)
        let ask = Plan(target: .ask, selected: picked)
        #expect(ask.affectedLoginIDs == ["auto"])
        #expect(ask.willRevokeLeasesCount == 2)
        #expect(ask.willDeleteSecretsCount == 0)
        let automatic = Plan(target: .automatic, selected: picked)
        #expect(automatic.affectedLoginIDs == ["ask", "gone"])
        #expect(automatic.needsReimportCount == 1)
        #expect(automatic.willRevokeLeasesCount == 0)
        #expect(Plan(target: .ask, selected: [picked[1]]).isNoOp)
    }

    @Test("LoginRuleStore writes AKRRUL02 protobuf, reads bytes it cannot decode as no rules, and throws when the keychain cannot be read")
    func policyStoreProtobufAndCorrupt() throws {
        var stored: Data?
        let store = LoginRuleStore(read: { stored }, write: { stored = $0 })
        let entries: [UUID: LoginRuleTimestampEntry] = [
            UUID(): LoginRuleTimestampEntry(.automatic, updatedAtMs: 1234, actor: "mac-1"),
            UUID(): LoginRuleTimestampEntry(.blocked, updatedAtMs: 5678, actor: "iphone-1"),
        ]
        try store.save(entries)
        #expect(try #require(stored).starts(with: LoginRuleStore.protobufMagic))
        #expect(try store.loadAccessRules() == entries)

        stored = LoginRuleStore.protobufMagic + Data([0xff, 0xff, 0x01])
        #expect(try store.loadAccessRules().isEmpty)
        stored = Data("{not-a-rule-set".utf8)
        #expect(try store.loadAccessRules().isEmpty)
        let locked = LoginRuleStore(read: { throw CocoaError(.fileReadNoPermission) }, write: { _ in })
        #expect(throws: CocoaError.self) { _ = try locked.loadAccessRules() }
    }
}
