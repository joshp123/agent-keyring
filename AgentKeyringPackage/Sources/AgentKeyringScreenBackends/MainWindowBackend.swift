// Written by AI on 2026.11.18 by model claude opus 5.5; Devices rebuilt on
// 2026.11.21 by the same model for the direct design.
//
// The Passwords and Devices tabs over the rules, the usage log, the members
// list and iCloud. Every value is read fresh from the model each time
// anything changes; nothing here is remembered.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import AgentKeyringEngine
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import LocalAuthentication
import Observation

@available(macOS 26.0, *)
@MainActor
public final class AppMainWindowBackend: MainWindowBackend {
    private let model: MacKeyringEngine
    /// The Touch ID dialog a rule change, removal or rename is waiting on, so Cancel can close it.
    private var asking: LAContext?

    public init(model: MacKeyringEngine) {
        self.model = model
    }

    public func snapshot() -> MainSnapshot {
        _ = model.vaultCategoriesRevision
        let testPassword = model.status?.testPasswordID
        let live = model.leaseStore.leases.filter { $0.state == .waiting || $0.state == .approved }
        let liveByLogin = Dictionary(grouping: live, by: \.loginID)
        let logins = model.accessControl.rows.map {
            let used = model.usage.usage[$0.id.uuidString] ?? PasswordUsage()
            let site = $0.website.isEmpty ? $0.title : $0.website
            let category = DomainClassifier.classify(site: site)
                ?? OnDeviceCategoryClassifier.shared.cachedCategory(forSite: site)
                ?? .other
            let leases = liveByLogin[$0.id.uuidString] ?? []
            return LoginRow(id: $0.id, site: site, account: $0.account, rule: $0.rule,
                category: category,
                asked: used.asked, approved: used.approved, denied: used.denied, isTestPassword: $0.id == testPassword,
                secretDeleted: $0.secretDeleted, activeLeases: leases.count,
                automaticLeases: leases.filter { model.accessRequest(for: $0).byAutomaticRule }.count)
        }
        let device = model.device
        let listed = devices()
        let remote = (device?.remoteAsks.values.map { RemoteRequestBackend.accessRequest($0, members: device?.members) } ?? [])
        let requests = model.leaseStore.leases.map(model.accessRequest(for:)) + remote
        let enrolments = device?.joins.map(JoinScreenMapping.enrolment) ?? []
        return MainSnapshot(logins: logins, importedAt: model.status?.importedAt, sampleOnly: model.status?.sampleOnly == true,
            approvers: approvers(listed), computers: listed.computers.map { ComputerRow(id: $0.id, name: $0.name) }, notices: notices(),
            // While Touch ID asks, the banner waits.
            unsentChanges: model.sendingChanges ? 0 : model.unsentChanges.total, copyChangedNothing: model.lastCopyChangedNothing,
            copyIsStale: model.status?.sampleOnly != true && StalePasswordsReminders.isStale(importedAt: model.status?.importedAt),
            remindsToUpdate: model.syncReminders?.isEnabled, opensAtLogin: model.opensAtLogin,
            anonymousTelemetry: model.anonymousTelemetry, requests: requests, enrolments: enrolments)
    }

    /// The members list as both screens list it: a Mac whose agents also ask is one row. This Mac's own
    /// computer is never listed as another computer, even when this Mac only asks.
    private func devices() -> DevicesSnapshot {
        let members = model.device?.members
        let ownMachine = model.device?.ownMachineID
        let devices = (members?.devices ?? []).compactMap { member -> SignedListDevice? in
            let kind: SignedListDeviceKind? = switch member.kind {
            case .iphone: .iPhone
            case .watch: .watch
            case .mac: .mac
            case .unspecified, .UNRECOGNIZED: nil
            }
            return kind.map { .init(id: member.keyID, name: member.label, kind: $0) }
        }
        let computers = (members?.machines ?? []).filter { $0.machineID != ownMachine }.map { SignedListComputer(id: $0.machineID, name: $0.label) }
        return DevicesSnapshot(devices: devices, computers: computers, thisDeviceID: model.thisMacDeviceKey) { id in
            members.map { CredentialSealing.pairedMac(id, in: $0) } ?? []
        }
    }

    /// This Mac, then each other device in the members list. Before anything has joined, the members
    /// list does not exist: this Mac alone.
    private func approvers(_ listed: DevicesSnapshot) -> [ApproverRow] {
        let device = model.device
        let own = model.thisMacDeviceKey
        let thisMacName = listed.approvers.first { $0.id == own }?.device.name ?? Host.current().localizedName ?? "Mac"
        // The Mac pushes a practice request itself, answered through the relay: it must hold a push key.
        let canPush = device?.hasPushKey == true
        let thisMacReady = MacApprover.shared.state == .ready
        let thisMac = ApproverRow(id: own, kind: .thisMac, name: thisMacName, practice: practice(own, here: true),
            // The practice card appears only while Touch ID can be used (the lid open, a fingerprint added).
            canPractise: thisMacReady && model.practiceResults[own] != .sent,
            readiness: thisMacReady ? .ready : .unavailable)
        return listed.macApprovers(thisMac: thisMac, readiness: { approver in
            if let filling = device?.filling, filling.deviceKeyID == approver.id {
                .syncingCopies(done: filling.done, total: filling.total)
            } else if !canPush {
                .unavailable
            } else if device?.hasPushRegistration(for: approver.id) != true {
                .waitingForNotifications
            } else {
                .ready
            }
        }, practice: { practice($0.id, here: false) })
    }

    private func practice(_ key: String, here: Bool) -> PracticeStatus? {
        switch model.practiceResults[key] {
        case nil: nil
        case .sent?: here ? .waitingHere : .sending
        case .withApple?: .withApple
        case .approved?: .approved
        case .denied?: .denied
        case .unanswered?: .noAnswer
        case let .failed(sentence)?: .failed(sentence)
        }
    }

    /// What stops this Mac reaching its other devices or computers, shown only when other devices or computers exist.
    private func notices() -> [DevicesNotice] {
        guard let device = model.device else { return [] }
        let hasMobileDevice = (device.members?.devices ?? []).contains { $0.kind == .iphone || $0.kind == .watch }
        var notices: [DevicesNotice] = []
        if hasMobileDevice, device.cloudState == .signedOut { notices.append(.noICloud) }
        if hasMobileDevice, !device.hasPushKey { notices.append(.noPushKey) }
        return notices
    }

    public func mainWindowSnapshotUpdates() -> AsyncStream<MainSnapshot> {
        stream(Observations { [weak self] in self?.snapshot() ?? MainSnapshot(logins: [], importedAt: nil) })
    }

    /// One Touch ID for every change, with our sentence in macOS's dialog.
    public func saveLoginRules(_ changes: [UUID: LoginRule]) async throws {
        let rows = model.accessControl.rows.filter { changes[$0.id] != nil }
        let automatic = rows.filter { changes[$0.id] == .automatic }
        let computers = [MainWindowCopy.thisMacInSentence] + (model.device?.members?.machines ?? [])
            .filter { $0.machineID != model.device?.ownMachineID }.map(\.label)
        func site(_ row: AccessCredentialRow) -> String { row.website.isEmpty ? row.title : row.website }
        let reason: String
        if automatic.count == 1, let row = automatic.first {
            reason = MainWindowCopy.automaticReason(computers, site: site(row))
        } else if automatic.count > 1 {
            reason = MainWindowCopy.automaticReason(computers, count: automatic.count)
        } else if rows.count == 1, let row = rows.first, let next = changes[row.id] {
            reason = MainWindowCopy.changeReason(site: site(row), from: row.rule.name, to: next.name)
        } else {
            reason = MainWindowCopy.changeReason(count: rows.count)
        }
        try await asked { context in
            try await confirmed { try await model.confirmOwner(context, reason: reason) }
            await model.accessControl.setRules(changes, context: context)
            if let message = model.accessControl.errorMessage { throw ScreenFailure(message: message) }
        }
    }

    public func cancelAuthentication() { asking?.invalidate() }

    /// Runs `action` with a new context, held so `cancelAuthentication` can close its dialog.
    private func asked(_ action: @MainActor (LAContext) async throws -> Void) async throws {
        let context = LAContext()
        asking = context
        defer { context.invalidate(); if asking === context { asking = nil } }
        try await action(context)
    }

    public func sendPracticeRequest(deviceID: String) { Task { await model.sendPracticeRequest(to: deviceID) } }

    public func sendUnsentChanges() async throws {
        try await confirmed {
            try await model.publishChangesThrowing()
        }
    }

    public func syncWithICloudNow() { model.syncWithICloudNow() }

    public func resetKeyring(includingICloud: Bool) async throws {
        try await model.resetKeyring(includingICloud: includingICloud)
    }

    public func setOpensAtLogin(_ on: Bool) { model.setOpensAtLogin(on) }
    public func setAnonymousTelemetry(_ on: Bool) { model.setAnonymousTelemetry(on) }

    public func setPasswordCopyReminder(_ on: Bool) {
        Task { [model] in
            await model.syncReminders?.setEnabled(on)
            await model.checkPasswordCopyFreshness()
        }
    }

    public func removeDevice(id: String) async throws {
        guard let device = model.device else { return }
        try await asked { context in try await confirmed { try await device.removeConfirmed(id, context: context) } }
    }

    public func renameDevice(id: String, to newName: String) async throws {
        guard let device = model.device else { return }
        try await asked { context in try await confirmed { try await device.renameConfirmed(id, to: newName, context: context) } }
    }

    /// Add Passwords: opens the selective import flow in place of the list.
    public func importAgain() { model.openPasswordsCopyFlow() }

    public func addManualPassword(website: String, account: String, password: String, totpSecret: String?, rule: LoginRule) async throws {
        try await model.addManualPassword(
            website: website,
            account: account,
            password: password,
            totpSecret: totpSecret,
            rule: rule,
            showReceipt: false
        )
    }

    public func approveAccessRequest(id: String) async throws {
        let context = LAContext()
        defer { context.invalidate() }
        try await confirmed {
            if let device = model.device, device.remoteAsks[id] != nil {
                _ = try await device.approveRemote(id, context: context, onAuthenticated: {})
                return
            }
            _ = try await model.approveLeaseWithTouchID(id, context: context, onAuthenticated: {})
        }
    }

    public func denyAccessRequest(id: String, reply: String?) async throws {
        try await screenErrors {
            if let device = model.device, device.remoteAsks[id] != nil {
                _ = try await device.denyRemote(id, reply: reply ?? "")
                return
            }
            _ = try model.denyLease(id, reply: reply ?? "")
        }
    }

    public func approveEnrolment(id: String) async throws {
        guard let device = model.device else { throw ScreenFailure(message: MessageCopy.noKeysYet) }
        let context = LAContext()
        defer { context.invalidate() }
        try await confirmed {
            try await device.approveJoin(id, context: context, onAuthenticated: {})
        }
    }

    public func denyEnrolment(id: String) async throws {
        _ = model.device?.refuseJoin(id, reply: "")
    }

    private func confirmed(_ action: () async throws -> Void) async throws {
        do { try await screenErrors(action) }
        catch let error as CredentialReleaseAuthorizationError where error.isCancel { throw CancellationError() }
    }
}
#endif
