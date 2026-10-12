import AgentKeyringTestSupport
import AuthenticationServices
import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Rejected login sync")
@MainActor
struct MirrorSyncRequestTests {
    @Test("Sync at night marks matching logins, find and approval show it, and import clears it")
    func rejectedLoginFlow() async throws {
        try await MacOwner.$fullName.withValue("Alex Example") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let settingsName = UUID().uuidString
            let settings = UserDefaults(suiteName: settingsName)!
            defer { settings.removePersistentDomain(forName: settingsName) }
            settings.set(false, forKey: "includeExampleCredential")
            let importedData = SyncFixtureImporter.data()
            let generation = try SnapshotMerger().merge(previous: nil,
                importBatch: CredentialExchangeMapper().map(importedData, scope: .full))
            let store = EncryptedSnapshotStore(directoryURL: directory.appendingPathComponent("vault"),
                keyProvider: StaticVaultKeyProvider(keyData: Data(repeating: 0x42, count: 32)))
            try await store.save(generation)
            let bridge = AgentBridgeDirectory(rootURL: directory.appendingPathComponent("bridge"))
            let authorizer = StaleApprovalRecorder()
            let model = MirrorAppModel(store: store, credentialImporter: SyncFixtureImporter(),
                authorizer: authorizer, bridge: bridge,
                accessControl: CredentialAccessController(store: CredentialAccessPolicyStore(
                    fileURL: directory.appendingPathComponent("policies.json"), signer: FakeAccessRulesSigner())), settings: settings)
            let notifier = FakeSyncNotifier()
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 0))!
            model.syncReminders = MirrorSyncReminders(settings: settings, notifier: notifier,
                now: { midnight }, calendar: calendar)
            // A recent mirror still needs sync if a login was rejected.
            let response = try await send(.sync, model: model, bridge: bridge)
            #expect(response.ok)
            #expect(model.accessControl.needsConfirmation)
            #expect(notifier.ages.count == 1)
            #expect(model.staleLogins.credentialIDs == Set(generation.items.map(\.id)))
            #expect(PossiblyStaleLogins(settings: settings).credentialIDs == model.staleLogins.credentialIDs)
            let find = try await send(.resolve, model: model, bridge: bridge)
            #expect(find.ok)
            #expect(find.candidates?.first?.isPossiblyStale == true)
            #expect(model.accessControl.needsConfirmation)
            let status = try await send(.status, model: model, bridge: bridge)
            #expect(status.ok)
            #expect(status.message == "Access rules need Alex's confirmation in Agent Keyring; nothing will be released until then.")
            await model.accessControl.confirmRules()
            #expect(!model.accessControl.needsConfirmation)
            let processor = AgentCredentialReleaseProcessor(bridge: bridge, accessControl: model.accessControl,
                approvals: CredentialApprovalCoordinator(lockState: UnlockedSyncTestSession()),
                possiblyStaleCredentialIDs: model.staleLogins.credentialIDs)
            let releaseRequest = AgentBridgeRequest(action: .acquire,
                targetURL: "https://example.com", field: .password)
            try bridge.write(releaseRequest)
            do {
                _ = try await processor.release(request: releaseRequest, generation: generation,
                    authorize: authorizer.authorize)
                Issue.record("The recording authorizer declines")
            } catch let error as CredentialReleaseAuthorizationError { #expect(error == .denied) }
            #expect(authorizer.approval?.isPossiblyStale == true)
            #expect(authorizer.approval?.localizedReason.contains("may be stale") == true)
            await model.importCredentials(token: UUID())
            #expect(model.notice?.kind == .information)
            #expect(model.staleLogins.credentialIDs.isEmpty)
            let afterImport = try await send(.resolve, model: model, bridge: bridge)
            #expect(afterImport.candidates?.first?.isPossiblyStale == false)
        }
    }

    @Test("Sync with no matching login neither marks nor notifies")
    func unmatchedSite() async throws {
        let settingsName = UUID().uuidString
        let settings = UserDefaults(suiteName: settingsName)!
        defer { settings.removePersistentDomain(forName: settingsName) }
        let model = MirrorAppModel(settings: settings)
        let notifier = FakeSyncNotifier()
        model.syncReminders = MirrorSyncReminders(settings: settings, notifier: notifier)
        let generation = try SnapshotMerger().merge(previous: nil,
            importBatch: CredentialExchangeMapper().map(SyncFixtureImporter.data(), scope: .full))
        do {
            _ = try await model.processSync(request: AgentBridgeRequest(action: .sync,
                targetURL: "https://other.example"), metadata: generation.metadata)
            Issue.record("An unmatched site must fail")
        } catch let error as CredentialResolverError { #expect(error == .notFound) }
        #expect(model.staleLogins.credentialIDs.isEmpty)
        #expect(notifier.ages.isEmpty)
    }

    private func send(_ action: AgentBridgeAction, model: MirrorAppModel,
                      bridge: AgentBridgeDirectory) async throws -> AgentBridgeResponse {
        let request = AgentBridgeRequest(action: action, targetURL: "https://example.com", field: .password)
        try bridge.write(request)
        await model.handleAgentRequest(id: request.id)
        return try bridge.readResponse(id: request.id)
    }
}

@MainActor
private final class StaleApprovalRecorder: CredentialReleaseAuthorizing {
    var approval: CredentialReleaseAuthorizationRequest?
    func authorize(_ request: CredentialReleaseAuthorizationRequest, onPromptStarted: @escaping () -> Void) async throws {
        approval = request
        throw CredentialReleaseAuthorizationError.denied
    }
}

private struct SyncFixtureImporter: CredentialImporting {
    func importCredentials(token: UUID) async throws -> ASExportedCredentialData { Self.data() }

    static func data() -> ASExportedCredentialData {
        let item = ASImportableItem(id: Data("item".utf8), created: Date(), lastModified: Date(),
            title: "Example", scope: ASImportableCredentialScope(urls: [URL(string: "https://example.com")!]),
            credentials: [.basicAuthentication(ASImportableCredential.BasicAuthentication(
                userName: ASImportableEditableField(id: nil, fieldType: .string, value: "synthetic"),
                password: ASImportableEditableField(id: nil, fieldType: .concealedString, value: "SYNTHETIC")))])
        let account = ASImportableAccount(id: Data("account".utf8), userName: "", email: "", collections: [], items: [item])
        return ASExportedCredentialData(accounts: [account], formatVersion: .v1,
            exporterRelyingPartyIdentifier: "com.apple.Passwords", exporterDisplayName: "Passwords", timestamp: Date())
    }
}

private struct UnlockedSyncTestSession: CredentialSessionLockState {
    var isLocked: Bool { false }
}
