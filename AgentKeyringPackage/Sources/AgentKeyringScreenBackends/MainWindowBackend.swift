// Written by AI on 2026.11.18 by model claude opus 5.5; Devices rebuilt on
// 2026.11.21 by the same model for the direct design.
//
// The Passwords and Devices tabs over the rules, the usage log, the members
// list and the door. Every value is read fresh from the model each time
// anything changes; nothing here is remembered.

#if os(macOS)
import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringProtocol
import Foundation
import LocalAuthentication
import Observation

@available(macOS 26.0, *)
@MainActor
public final class AppMainWindowBackend: MainWindowBackend {
    private let model: MirrorAppModel

    public init(model: MirrorAppModel) {
        self.model = model
    }

    public func snapshot() -> MainSnapshot {
        let testPassword = model.status?.testPasswordID
        let logins = model.accessControl.rows.map {
            let used = model.usage.usage[$0.id.uuidString] ?? PasswordUsage()
            return LoginRow(id: $0.id, site: $0.website.isEmpty ? $0.title : $0.website, account: $0.account, rule: LoginRule($0.policy),
                asked: used.asked, approved: used.approved, denied: used.denied, isTestPassword: $0.id == testPassword)
        }
        let device = model.device
        let others = (device?.members?.machines ?? []).filter { $0.machineID != device?.ownMachineID }
        return MainSnapshot(logins: logins, importedAt: model.status?.importedAt, sampleOnly: model.status?.sampleOnly == true,
            approvers: approvers(), computers: others.map { ComputerRow(id: $0.machineID, name: $0.label) }, notices: notices(),
            // While the panel asks, the banner waits.
            unsentChanges: model.resyncAsked ? 0 : model.unsentChanges.total)
    }

    /// This Mac, then each iPhone and Apple Watch in the members list. Before
    /// anything has joined, the members list does not exist: this Mac alone.
    private func approvers() -> [ApproverRow] {
        let device = model.device
        let own = model.thisMacDeviceKey
        let devices = device?.members?.devices ?? []
        let thisMacName = devices.first { $0.keyID == own }?.label ?? Host.current().localizedName ?? "Mac"
        // The Mac pushes a practice request itself: its door must be open and it must hold the push key.
        let canPush: Bool = if case .open = device?.door, device?.hasPushKey == true { true } else { false }
        let thisMac = ApproverRow(id: own, kind: .thisMac, name: thisMacName, practice: practice(own, here: true),
            // The practice card appears only while Touch ID can be used (the lid open, a fingerprint added).
            canPractise: model.practiceResults[own] != .sent && MacApprover.shared.state == .ready)
        return [thisMac] + devices.filter { $0.keyID != own && ($0.kind == .iphone || $0.kind == .watch) }.map { member in
            let practice = practice(member.keyID, here: false)
            return ApproverRow(id: member.keyID, kind: member.kind == .watch ? .watch : .iPhone, name: member.label, practice: practice,
                canPractise: canPush && practice?.isUnderWay != true)
        }
    }

    private func practice(_ key: String, here: Bool) -> PracticeStatus? {
        switch model.practiceResults[key] {
        case nil: nil
        case .sent?: here ? .waitingHere : .sending
        case .withApple?: .withApple
        case .arrived?: .arrived
        case .approved?: .approved
        case .denied?: .denied
        case .unanswered?: .noAnswer
        case let .failed(sentence)?: .failed(sentence)
        }
    }

    /// What stops this Mac reaching his other devices, from the door and the push key as they are now.
    private func notices() -> [DoorNotice] {
        guard let device = model.device else { return [] }
        var notices: [DoorNotice] = switch device.door {
        case .noTailscale: [.noTailscale]
        case .failed: [.failed]
        case .opening, .open: []
        }
        if !device.hasPushKey { notices.append(.noPushKey) }
        return notices
    }

    public func updates() -> AsyncStream<MainSnapshot> {
        stream(Observations { [weak self] in self?.snapshot() ?? MainSnapshot(logins: [], importedAt: nil) })
    }

    /// One Touch ID for every change, with our sentence in macOS's dialog.
    public func saveRules(_ changes: [UUID: LoginRule], context: LAContext) async throws {
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
            reason = MainWindowCopy.changeReason(site: site(row), from: LoginRule(row.policy).name, to: next.name)
        } else {
            reason = MainWindowCopy.changeReason(count: rows.count)
        }
        try await confirmed { try await OwnerConfirmation.confirm(context, reason: reason, until: .now.addingTimeInterval(600)) }
        await model.accessControl.setPolicies(changes.mapValues(CredentialAccessPolicy.init), context: context)
        if let message = model.accessControl.errorMessage { throw ScreenFailure(message: message) }
    }

    public func sendPractice(deviceID: String) { Task { await model.sendPractice(to: deviceID) } }

    public func sendUpdates() { model.askToSendChanges() }

    public func remove(id: String, context: LAContext) async throws {
        guard let device = model.device else { return }
        try await confirmed { try await device.removeConfirmed(id, context: context) }
    }

    /// Copy Again: Passwords opens, and the window shows the steps until the passwords arrive.
    public func importAgain() { model.openPasswordsExport() }

    private func confirmed(_ action: () async throws -> Void) async throws {
        do { try await screenErrors(action) }
        catch let error as CredentialReleaseAuthorizationError where error.isCancel { throw CancellationError() }
    }
}
#endif
