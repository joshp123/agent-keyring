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
        let devices = SetupScreens.practiceRows(model).map { DeviceRow(practice: $0, isThisMac: $0.id == model.thisMacDeviceKey) }
        let machines: [MachineRow] = device?.members.map { members in
            members.machines.map { m in
                MachineRow(id: m.machineID, name: m.label, isThisMac: m.machineID == device?.ownMachineID,
                    isAlwaysOn: m.machineID == device?.alwaysOnMachineID)
            }
        } ?? [MachineRow(id: device?.ownMachineID ?? "this-mac", name: Host.current().localizedName ?? "Mac", isThisMac: true, isAlwaysOn: false)]
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

    public func sendPractice(deviceID: String) { Task { await model.sendPractice(to: deviceID) } }

    public func remove(id: String, context: LAContext) async throws {
        guard let device = model.device else { return }
        try await confirmed { try await device.removeConfirmed(id, context: context) }
    }

    /// Copy from Passwords: Passwords opens, and the window shows the steps until the passwords arrive.
    public func importAgain() { model.openPasswordsExport() }

    /// "Connect a computer of yours that stays on": the address of the relay
    /// already running there ("100.64.0.5:17445" or "mac-mini:17445"), then
    /// Touch ID. Onboarding and Add Computer in Devices use the same.
    public func connectRelay(_ address: String, onAuthenticated: @MainActor () -> Void = {}) async throws {
        guard let device = model.device else { throw ScreenFailure(message: "This Mac has no keys yet.") }
        let parts = address.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            throw ScreenFailure(message: "Enter the computer's address and the relay's port, such as mac-mini:17445.")
        }
        try await screenErrors {
            try await device.connect(to: try RelayEndpoint(host: String(parts[0]), port: port), context: LAContext(), onAuthenticated: onAuthenticated)
        }
    }

    private func confirmed(_ action: () async throws -> Void) async throws {
        do { try await screenErrors(action) }
        catch let error as CredentialReleaseAuthorizationError where error.isCancel { throw CancellationError() }
    }
}
#endif
