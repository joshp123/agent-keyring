// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The Passwords and Devices tabs over the rules, the sealed copies and the relay.

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
        let logins = model.accessControl.rows.map {
            LoginRow(id: $0.id, site: $0.website.isEmpty ? $0.title : $0.website, account: $0.account, rule: LoginRule($0.policy))
        }
        let device = model.device
        let members = device?.members
        let tested = device?.lastTested ?? [:]
        let macTested = model.testedAt
        let devices: [DeviceRow] = members.map { members in
            members.devices.map { d in
                DeviceRow(id: d.keyID, name: d.label, kind: d.kind == .iphone ? .iPhone : d.kind == .watch ? .watch : .mac,
                    lastTested: d.keyID == device?.ownDeviceID ? macTested : tested[d.keyID], isThisMac: d.keyID == device?.ownDeviceID)
            }
        } ?? [DeviceRow(id: "this-mac", name: Host.current().localizedName ?? "Mac", kind: .mac, lastTested: macTested, isThisMac: true)]
        let machines: [MachineRow] = members.map { members in
            members.machines.map { m in
                MachineRow(id: m.machineID, name: m.label, isThisMac: m.machineID == device?.ownMachineID,
                    isAlwaysOn: m.machineID == device?.alwaysOnMachineID, automatic: m.automaticAllowed, lastTested: nil)
            }
        } ?? [MachineRow(id: device?.ownMachineID ?? "this-mac", name: Host.current().localizedName ?? "Mac", isThisMac: true,
            isAlwaysOn: false, automatic: model.automaticOnThisMac, lastTested: nil)]
        return MainSnapshot(logins: logins, importedAt: model.status?.importedAt, sampleOnly: model.status?.sampleOnly == true,
            devices: devices, machines: machines)
    }

    public func updates() -> AsyncStream<MainSnapshot> {
        stream(Observations { [weak self] in self?.snapshot() ?? MainSnapshot(logins: [], importedAt: nil, devices: [], machines: []) })
    }

    /// One Touch ID for every change, with our sentence in macOS's dialog.
    public func saveRules(_ changes: [UUID: LoginRule], context: LAContext) async throws {
        let rows = model.accessControl.rows.filter { changes[$0.id] != nil }
        let automatic = rows.filter { changes[$0.id] == .automatic }
        let computers = ["this Mac"] + (model.device?.members?.machines ?? [])
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

    public func setAutomatic(machineID: String, on: Bool, context: LAContext) async throws {
        let label = machineID == model.device?.ownMachineID ? nil : model.device?.members?.machines.first { $0.machineID == machineID }?.label
        try await confirmed {
            try await OwnerConfirmation.confirm(context, reason: MainWindowCopy.automaticReason(label, on: on), until: .now.addingTimeInterval(600))
            try await model.setAutomatic([machineID: on], context: context)
        }
    }

    public func remove(id: String, context: LAContext) async throws {
        guard let device = model.device else { return }
        try await confirmed { try await device.removeConfirmed(id, context: context) }
    }

    public func importAgain() { model.openPasswordsExport() }

    private func confirmed(_ action: () async throws -> Void) async throws {
        do { try await screenErrors(action) }
        catch let error as CredentialReleaseAuthorizationError where error.isCancel { throw CancellationError() }
    }
}
#endif
