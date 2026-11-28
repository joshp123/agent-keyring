// Written by AI on 2026.11.23 by model claude opus 5.5.
// Real persistence and multi-Mac safety invariants.

@testable import AgentKeyringApprovalUI
@testable import AgentKeyringEngine
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringScreenBackends
import AgentKeyringSealing
import Foundation
import LocalAuthentication
import Testing

struct ThisMacSetupTests {
    @Test("Keys are only ever added: a second launch making keys gets the first one's, unchanged")
    @MainActor func keysAreOnlyAdded() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ThisMacSetupTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "keys.plist")
        let tls = try DeviceTLSIdentity.ephemeral()
        #expect(try MacKeys.loadMacKeys(softwareKeyFile: file, tls: tls) == nil)
        let first = try MacKeys.make(.devicePassword, softwareKeyFile: file, tls: tls)
        #expect(throws: MacKeysError.alreadyMade) { try MacKeys.make(.biometricOrCompanion, softwareKeyFile: file, tls: tls) }
        let loaded = try #require(try MacKeys.loadMacKeys(softwareKeyFile: file, tls: tls))
        #expect(loaded.deviceKeyID == first.deviceKeyID)
        #expect(loaded.mode == .devicePassword)
    }

    @Test("A new install removes the iCloud invitation only if this Mac left it")
    @MainActor func newInstallKeepsAnotherMacsInvitation() {
        final class Left { var invite: Agentkeyring_V2_JoinInvite?; var removed = false }
        func run(leftBy inviter: String, ownKeyID: String?) -> Bool {
            let suite = "ThisMacSetupTests-\(UUID().uuidString)"
            let settings = UserDefaults(suiteName: suite)!
            defer { settings.removePersistentDomain(forName: suite) }
            let left = Left()
            var invite = Agentkeyring_V2_JoinInvite()
            invite.inviterKeyID = inviter
            left.invite = invite
            let item = CloudKeychainInvitationStore(read: { left.invite }, write: { left.invite = $0; return true }, remove: { left.removed = true })
            MacKeyringEngine.forgetPreviousInstall(settings: settings, invitation: item, ownKeyID: { ownKeyID }, forgetLocalRecords: {})
            #expect(settings.bool(forKey: MacKeyringEngine.installedKey))
            return left.removed
        }
        #expect(!run(leftBy: "personal-macbook", ownKeyID: nil))
        #expect(!run(leftBy: "personal-macbook", ownKeyID: "this-mac"))
        #expect(run(leftBy: "this-mac", ownKeyID: "this-mac"))
    }

    @Test("A second personal Mac leaves the first Mac's iCloud invitation alone until Add your iPhone is opened")
    @MainActor func secondMacKeepsFirstMacsInvitation() throws {
        final class Left: @unchecked Sendable { var invite: Agentkeyring_V2_JoinInvite? }
        let folder = FileManager.default.temporaryDirectory.appending(path: "ThisMacSetupTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let left = Left()
        var first = Agentkeyring_V2_JoinInvite()
        first.inviterKeyID = "personal-macbook"
        first.inviterLabel = "MacBook Pro"
        first.secret = Data(repeating: 7, count: 32)
        left.invite = first
        var environment = MacSyncEnvironment(storage: .memory())
        environment.invitationStore = CloudKeychainInvitationStore(read: { left.invite }, write: { left.invite = $0; return true })
        let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Mac Studio")
        let mac = MacSyncCoordinator(keys: keys, store: MacVaultFileStore(directory: folder.appending(path: "logins")),
                            leaseStore: CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: "leases"))),
                            environment: environment) { [] }
        mac.leaveInvitation()
        #expect(left.invite == first)
        mac.leaveInvitationForIPhone()
        #expect(left.invite?.inviterKeyID == keys.deviceKeyID)
    }

    @Test("Resetting this Mac clears logins, rules, leases, and first-run state without leaving a stale invitation")
    @MainActor func macResetClearsLocalStateAndReturnsToWelcome() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MacResetTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "MacResetTests-\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: suite)!
        defer { settings.removePersistentDomain(forName: suite) }
        let loginsFolder = folder.appending(path: "logins")
        let leasesFolder = folder.appending(path: "leases")
        let rulesFile = folder.appending(path: "rules.pb")
        func rulesStore() -> LoginRuleStore {
            LoginRuleStore(read: { try? Data(contentsOf: rulesFile) }, write: { try $0.write(to: rulesFile, options: .atomic) })
        }

        let login = StoredVaultLogin(id: UUID(),
                               sourceIdentity: LoginSourceIdentity(exporterIdentifier: "com.apple.Passwords", accountID: Data("acc".utf8), itemID: Data("bank".utf8)),
                               title: "bank.example", origins: ["https://bank.example"],
                               credentials: [.password(userName: "you", password: "pw")])
        let store = MacVaultFileStore(directory: loginsFolder)
        try await store.save(StoredVaultSnapshot(id: UUID(), previousSnapshotID: nil, createdAt: .now, sourceExportedAt: .now, scope: .selected,
                                              exporterIdentifier: "com.apple.Passwords", exporterDisplayName: "Passwords",
                                              items: [login], skippedCredentialCount: 0), sealed: [])
        try rulesStore().save([login.id: LoginRuleTimestampEntry(.blocked, updatedAtMs: 1, actor: "mac")])
        let leaseStore = CredentialLeaseStore(persistence: LeasePersistence(directory: leasesFolder))
        var asking = Agentkeyring_V2_RequestLeaseRequest()
        asking.loginID = login.id.uuidString
        asking.requestID = UUID().uuidString
        asking.taskRef = "statements"
        asking.reason = "Download this month's statement."
        let lease = try leaseStore.recordLeaseRequest(asking, login: CredentialCandidate(id: login.id, title: login.title, username: "you",
                                                                               origins: login.origins, availableFields: [.username, .password]),
                                           rule: .ask)

        let usageFile = folder.appending(path: "usage.json")
        let usage = PasswordUsageLog(file: usageFile)
        usage.noteUsage(.asked, request: lease.requestID, login: login.id.uuidString)
        let model = MacKeyringEngine(store: store,
                                   accessControl: CredentialAccessController(store: rulesStore()),
                                   leaseStore: leaseStore,
                                   usage: usage,
                                   settings: settings)
        #expect(model.accessControl.rule(for: login.id) == .blocked)
        model.sendFirstRunEvent(.getStarted)
        #expect(model.firstRun != .welcome)

        final class Calls: @unchecked Sendable { var zoneDeleted = false; var inviteRemoved = false }
        let calls = Calls()
        let invitation = CloudKeychainInvitationStore(read: { nil }, write: { _ in false }, remove: { calls.inviteRemoved = true })
        try await model.resetKeyring(includingICloud: true, invitation: invitation,
                              deleteCloudZone: { calls.zoneDeleted = true }, forgetLocalRecords: {})

        #expect(model.firstRun == .welcome)
        #expect(model.leaseLogins.isEmpty)
        #expect(model.status == nil)
        #expect(calls.zoneDeleted)
        #expect(calls.inviteRemoved)

        #expect(try await MacVaultFileStore(directory: loginsFolder).loadCurrent() == nil)
        #expect(try rulesStore().loadAccessRules().isEmpty)
        #expect(PasswordUsageLog(file: usageFile).usage.isEmpty)
        let reopenedLeases = CredentialLeaseStore(persistence: LeasePersistence(directory: leasesFolder))
        try reopenedLeases.loadLeaseRecords()
        #expect(reopenedLeases.waitingRequests.isEmpty)
        #expect(throws: (any Error).self) { try reopenedLeases.get(lease.requestID) }
        #expect(MacKeyringEngine.savedFirstRun(settings) == .welcome)
    }

    @Test("Resetting PhoneModel closes Settings and resets the backend, iCloud included")
    @MainActor func phoneModelResetClosesSettingsAndResetsBackend() async {
        let world = SandboxWorld()
        let model = PhoneModel(backend: world, initial: world.phoneSnapshot)
        model.openSettings()
        #expect(model.sheet.presentation == .settings)

        await model.resetKeyring(includingICloud: true)
        #expect(world.effects.ran == [.reset])
        #expect(world.state.phone.firstRun == .start)
        #expect(world.state.logins.isEmpty)
        #expect(model.sheet.presentation == .none)
    }

    @Test("Closed-lid Mac with paired Apple Watch reports ready and watch approver; without Watch reports lidClosed")
    func clamshellCompanionApprovalState() {
        let withWatch = MacProbe(secureEnclave: true, lidClosed: true, biometry: .systemCancel, companion: true)
        #expect(MacApprover.state(mode: .biometricOrCompanion, withWatch) == .ready)
        #expect(MacApprover.approver(mode: .biometricOrCompanion, withWatch) == .watch)

        let withoutWatch = MacProbe(secureEnclave: true, lidClosed: true, biometry: .systemCancel, companion: false)
        #expect(MacApprover.state(mode: .biometricOrCompanion, withoutWatch) == .lidClosed)
        #expect(MacApprover.approver(mode: .biometricOrCompanion, withoutWatch) == .none)
    }

    @Test("Mac floating panel skips auto-pop when unapprovable and pushed elsewhere, and dismisses promptly")
    func approvalPresentationPolicy() {
        #expect(!ApprovalPresentationPolicy.shouldAutoPresent(isRequest: true, approverState: .lidClosed, approvesElsewhere: true))
        #expect(!ApprovalPresentationPolicy.shouldAutoPresent(isRequest: true, approverState: .touchIDMissing, approvesElsewhere: true))
        #expect(ApprovalPresentationPolicy.shouldAutoPresent(isRequest: true, approverState: .lidClosed, approvesElsewhere: false))
        #expect(ApprovalPresentationPolicy.shouldAutoPresent(isRequest: true, approverState: .ready, approvesElsewhere: true))
        #expect(ApprovalPresentationPolicy.shouldAutoPresent(isRequest: false, approverState: .lidClosed, approvesElsewhere: true))

        #expect(ApprovalPresentationPolicy.dismissLinger(isSelfTest: true, answeredElsewhere: false) == .zero)
        #expect(ApprovalPresentationPolicy.dismissLinger(isSelfTest: false, answeredElsewhere: true) == .zero)
        #expect(ApprovalPresentationPolicy.dismissLinger(isSelfTest: false, answeredElsewhere: false) == .seconds(1))
    }

    @Test("MacFirstRunFlow and sentList round-trip as protobuf; other bytes read as nothing saved")
    @MainActor func firstRunAndSentListProtobuf() throws {
        let suite = "FirstRunStorageTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }

        let cases: [MacFirstRunFlow] = [
            .welcome,
            MacFirstRunFlow(step: .practice, practice: .denied(reply: "Use the invoice")),
            MacFirstRunFlow(step: .privacy, practice: .approved),
            MacFirstRunFlow(step: .copy, practice: .approved),
            MacFirstRunFlow(step: .connectAgent(.worked(agent: "Codex")), practice: .approved),
            MacFirstRunFlow(step: .connectAgent(.denied(agent: "Claude Code")), practice: .approved),
            MacFirstRunFlow(step: .ready, practice: .approved),
            .finished,
        ]
        for state in cases {
            let encoded = try state.encodeProtobuf()
            #expect(encoded.starts(with: MacFirstRunFlow.protobufMagic))
            #expect(try MacFirstRunFlow.decodeProtobuf(encoded) == state)
        }
        #expect(throws: (any Error).self) { try MacFirstRunFlow.decodeProtobuf(Data("{}".utf8)) }
        settings.set(Data("{}".utf8), forKey: MacKeyringEngine.firstRunKey)
        #expect(MacKeyringEngine.savedFirstRun(settings) == .welcome)

        let monday = Date(timeIntervalSince1970: 1_800_000_000)
        let sent: [String: Date?] = ["login-a": monday, "login-b": nil]
        MacKeyringEngine.saveSentList(sent, in: settings)
        let storedSent = try #require(settings.data(forKey: MacKeyringEngine.sentListKey))
        #expect(storedSent.starts(with: MacKeyringEngine.sentListProtobufMagic))
        #expect(MacKeyringEngine.savedSentList(settings) == sent)
        settings.set(Data("{}".utf8), forKey: MacKeyringEngine.sentListKey)
        #expect(MacKeyringEngine.savedSentList(settings) == nil)
    }

    @Test("AppMainWindowBackend exposes explicit ApproverRow.Readiness and disables practice until push registration arrives")
    @MainActor
    func approverReadinessReflectsNotificationRegistrationAndCopySync() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "akr-readiness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let suite = "akr-readiness-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }

        let macKeys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "MacBook Pro")
        let phoneKeys = OpeningCapablePhoneKeys()
        let phoneKeyID = try CredentialSealing.keyID(phoneKeys.signingPublicKey())
        var phoneDevice = Agentkeyring_V2_Device()
        phoneDevice.keyID = phoneKeyID
        phoneDevice.kind = .iphone
        phoneDevice.label = "Josh's iPhone"
        phoneDevice.signingPublicKey = try phoneKeys.signingPublicKey()
        phoneDevice.openingPublicKey = try phoneKeys.openingPublicKey()
        phoneDevice.replyPublicKey = try phoneKeys.replyPublicKey()
        phoneDevice.replyKeyID = try CredentialSealing.keyID(phoneKeys.replyPublicKey())
        phoneDevice.noticePublicKey = try phoneKeys.noticePublicKey()

        var members = Agentkeyring_V2_Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [macKeys.device, phoneDevice]
        members.machines = [macKeys.machine]
        let signedMembersBytes = try CredentialSealing.signedDocument(members.serializedData(), by: macKeys.deviceKeyID) {
            try macKeys.signWithDeviceKey($0, context: LAContext())
        }.serializedData()

        var env = MacSyncEnvironment(storage: .memory())
        env.pushRelayURL = URL(string: "https://push.test")!
        let model = MacKeyringEngine(
            store: MacVaultFileStore(directory: folder.appending(path: "store")),
            accessControl: CredentialAccessController(store: LoginRuleStore(read: { nil }, write: { _ in })),
            leaseStore: CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: "leases"))),
            settings: settings
        )
        model.enableBackgroundOnDeviceSorting = false
        model.adopt(macKeys, environment: env, leavingInvitation: false)
        let macDevice = try #require(model.device)
        #expect(await macDevice.receiveSignedMembers(signedMembersBytes) == .taken)

        let backend = AppMainWindowBackend(model: model)

        // Dumped for the sandbox, the list keeps both devices, and this Mac's computer as its other half.
        let dumped = try SandboxBundleCodec.state(from: backend.sandboxBundle(model: model))
        #expect(Set(dumped.devices.map(\.id)) == [macKeys.deviceKeyID, phoneKeyID])
        #expect(dumped.computers.map(\.pairedDeviceID) == [macKeys.deviceKeyID])
        #expect(dumped.thisDeviceID == macKeys.deviceKeyID)
        #expect(dumped.listed.computers.isEmpty)

        // Before iPhone sends its push registration: waitingForNotifications, cannot practise.
        let before = try #require(backend.snapshot().approvers.first { $0.id == phoneKeyID })
        #expect(before.readiness == DeviceReadiness.waitingForNotifications)
        #expect(!before.canPractise)
        #expect(!macDevice.hasPushRegistration(for: phoneKeyID))

        // While Mac is copying passwords to iPhone: syncingCopies, cannot practise.
        macDevice.filling = EnrollingDeviceCopyProgress(deviceKeyID: phoneKeyID, label: phoneDevice.label, done: 3, total: 10, failure: nil)
        let syncing = try #require(backend.snapshot().approvers.first { $0.id == phoneKeyID })
        #expect(syncing.readiness == DeviceReadiness.syncingCopies(done: 3, total: 10))
        #expect(!syncing.canPractise)
        macDevice.filling = nil

        // Once iPhone registers its APNs token: ready and canPractise == true.
        var registration = Agentkeyring_V2_PushRegistration()
        registration.domain = "agentkeyring.push.v2"
        registration.deviceKeyID = phoneKeyID
        registration.apnsToken = Data(repeating: 0xAA, count: 32)
        registration.apnsTopic = "com.joshpalmer.AgentKeyring.Phone"
        registration.apnsProduction = true
        registration.noticePublicKey = try phoneKeys.noticePublicKey()
        registration.registeredUnixSeconds = Int64(Date().timeIntervalSince1970)
        let signedReg = try CredentialSealing.signedDocument(registration.serializedData(), by: phoneDevice.replyKeyID) {
            try phoneKeys.signReply($0)
        }
        #expect(macDevice.cloudSync.receivePushRegistration(try signedReg.serializedData()) == .taken)
        #expect(macDevice.hasPushRegistration(for: phoneKeyID))

        let ready = try #require(backend.snapshot().approvers.first { $0.id == phoneKeyID })
        #expect(ready.readiness == DeviceReadiness.ready)
        #expect(ready.canPractise)

        // When Mac has no push key / relay configured: unavailable and cannot practise.
        var noPushEnv = MacSyncEnvironment(storage: .memory())
        noPushEnv.pushRelayURL = nil
        let noPushModel = MacKeyringEngine(
            store: MacVaultFileStore(directory: folder.appending(path: "store-nopush")),
            accessControl: CredentialAccessController(store: LoginRuleStore(read: { nil }, write: { _ in })),
            leaseStore: CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: "leases-nopush"))),
            settings: settings
        )
        noPushModel.enableBackgroundOnDeviceSorting = false
        noPushModel.adopt(macKeys, environment: noPushEnv, leavingInvitation: false)
        let noPushDevice = try #require(noPushModel.device)
        #expect(await noPushDevice.receiveSignedMembers(signedMembersBytes) == .taken)
        #expect(noPushDevice.cloudSync.receivePushRegistration(try signedReg.serializedData()) == .taken)
        let unavailable = try #require(AppMainWindowBackend(model: noPushModel).snapshot().approvers.first { $0.id == phoneKeyID })
        #expect(unavailable.readiness == DeviceReadiness.unavailable)
        #expect(!unavailable.canPractise)
    }

    @Test("devicesUnreachable requires a PushRegistration even when push relay is configured and phone is listed")
    @MainActor
    func devicesUnreachableRequiresPushRegistration() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "akr-unreachable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let macKeys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "MacBook Pro")
        let phoneKeys = OpeningCapablePhoneKeys()
        let phoneKeyID = try CredentialSealing.keyID(phoneKeys.signingPublicKey())
        var phoneDevice = Agentkeyring_V2_Device()
        phoneDevice.keyID = phoneKeyID
        phoneDevice.kind = .iphone
        phoneDevice.label = "Josh's iPhone"
        phoneDevice.signingPublicKey = try phoneKeys.signingPublicKey()
        phoneDevice.openingPublicKey = try phoneKeys.openingPublicKey()
        phoneDevice.replyPublicKey = try phoneKeys.replyPublicKey()
        phoneDevice.replyKeyID = try CredentialSealing.keyID(phoneKeys.replyPublicKey())
        phoneDevice.noticePublicKey = try phoneKeys.noticePublicKey()

        var members = Agentkeyring_V2_Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = 1
        members.devices = [macKeys.device, phoneDevice]
        members.machines = [macKeys.machine]
        let signedMembersBytes = try CredentialSealing.signedDocument(members.serializedData(), by: macKeys.deviceKeyID) {
            try macKeys.signWithDeviceKey($0, context: LAContext())
        }.serializedData()

        var env = MacSyncEnvironment(storage: .memory())
        env.pushRelayURL = URL(string: "https://push.test")!
        let device = MacSyncCoordinator(
            keys: macKeys,
            store: MacVaultFileStore(directory: folder.appending(path: "store")),
            leaseStore: CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: "leases"))),
            environment: env
        ) { [] }

        #expect(device.devicesUnreachable == MessageCopy.noIPhoneOrWatch)
        #expect(await device.receiveSignedMembers(signedMembersBytes) == .taken)
        #expect(device.devicesUnreachable == MessageCopy.noPushAddress(phoneDevice.label))

        var registration = Agentkeyring_V2_PushRegistration()
        registration.domain = "agentkeyring.push.v2"
        registration.deviceKeyID = phoneKeyID
        registration.apnsToken = Data(repeating: 0xAA, count: 32)
        registration.apnsTopic = "com.joshpalmer.AgentKeyring.Phone"
        registration.apnsProduction = true
        registration.noticePublicKey = try phoneKeys.noticePublicKey()
        registration.registeredUnixSeconds = Int64(Date().timeIntervalSince1970)
        let signedReg = try CredentialSealing.signedDocument(registration.serializedData(), by: phoneDevice.replyKeyID) {
            try phoneKeys.signReply($0)
        }
        #expect(device.cloudSync.receivePushRegistration(try signedReg.serializedData()) == .taken)
        #expect(device.devicesUnreachable == nil)
    }

    @Test("reset leaves running device and local data untouched if iCloud zone deletion fails")
    @MainActor
    func resetFailureLeavesDeviceRunning() async throws {
        struct CloudResetFailure: Error {}

        let folder = FileManager.default.temporaryDirectory.appending(path: "akr-reset-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let suite = "akr-reset-fail-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }

        let macKeys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "MacBook Pro")
        let store = MacVaultFileStore(directory: folder.appending(path: "store"))
        let leaseStore = CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: "leases")))
        let item = StoredVaultLogin(
            id: UUID(),
            sourceIdentity: LoginSourceIdentity(exporterIdentifier: "com.apple.Passwords", accountID: Data("a".utf8), itemID: Data("1".utf8)),
            lastModifiedAt: .now,
            title: "Example",
            origins: ["https://example.com"],
            credentials: [.password(userName: "alex@example.com", password: "secret")]
        )
        let generation = StoredVaultSnapshot(
            id: UUID(),
            previousSnapshotID: nil,
            createdAt: .now,
            sourceExportedAt: .now,
            scope: .selected,
            exporterIdentifier: "com.apple.Passwords",
            exporterDisplayName: "Passwords",
            items: [item],
            skippedCredentialCount: 0
        )
        let copy = try CredentialSealing.sealLogin(item.secret, version: 1, to: macKeys.openingPublicKey, openerID: macKeys.deviceKeyID, signer: macKeys.signer)
        try await store.save(generation) { _ in [copy] }

        settings.set(true, forKey: MacKeyringEngine.testedAtKey)
        let model = MacKeyringEngine(
            store: store,
            accessControl: CredentialAccessController(store: LoginRuleStore(read: { nil }, write: { _ in })),
            leaseStore: leaseStore,
            settings: settings
        )
        model.enableBackgroundOnDeviceSorting = false
        let loaded = try await store.loadCurrentMetadata()
        model.status = loaded?.safeStatus
        model.leaseLogins = loaded?.candidates ?? []

        var env = MacSyncEnvironment(storage: .memory())
        env.invitationStore = .nowhere
        model.adopt(macKeys, environment: env, leavingInvitation: false)
        let device = try #require(model.device)
        defer { device.stopBackgroundWork() }
        #expect(device.started)

        var forgotLocal = false
        await #expect(throws: CloudResetFailure.self) {
            try await model.resetKeyring(
                includingICloud: true,
                invitation: .nowhere,
                deleteCloudZone: { throw CloudResetFailure() },
                forgetLocalRecords: { forgotLocal = true }
            )
        }

        #expect(device.started)
        #expect(model.status != nil)
        #expect(!forgotLocal)
        #expect(try await store.loadCurrent() != nil)
        #expect(settings.bool(forKey: MacKeyringEngine.testedAtKey))
    }
}
