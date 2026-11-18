// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The Logins and Devices tabs over the rules, the sealed copies and the relay.

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
        let macTested: Date? = if case let .passed(at) = model.selfTest { at } else { nil }
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
        } ?? [MachineRow(id: "this-mac", name: Host.current().localizedName ?? "Mac", isThisMac: true, isAlwaysOn: false,
            automatic: true, lastTested: nil)]
        return MainSnapshot(logins: logins, importedAt: model.status?.importedAt, devices: devices, machines: machines,
            joined: device?.isJoined == true)
    }

    public func updates() -> AsyncStream<MainSnapshot> {
        stream(Observations { [weak self] in self?.snapshot() ?? MainSnapshot(logins: [], importedAt: nil, devices: [], machines: [], joined: false) })
    }

    /// One Touch ID for every change, with our sentence in macOS's dialog.
    public func saveRules(_ changes: [UUID: LoginRule], context: LAContext) async throws {
        let rows = model.accessControl.rows.filter { changes[$0.id] != nil }
        let reason: String
        if rows.count == 1, let row = rows.first, let next = changes[row.id] {
            reason = "change \(row.website.isEmpty ? row.title : row.website) from \(LoginRule(row.policy).name) to \(next.name)"
        } else {
            reason = "change the rules for \(rows.count) logins"
        }
        try await confirmed { try await OwnerConfirmation.confirm(context, reason: reason, until: .now.addingTimeInterval(600)) }
        await model.accessControl.setPolicies(changes.mapValues(CredentialAccessPolicy.init), context: context)
        if let message = model.accessControl.errorMessage { throw ScreenFailure(message: message) }
    }

    public func proposeRules(_ changes: [UUID: LoginRule]) async throws -> Bool {
        guard let device = model.device, device.isJoined else {
            throw ScreenFailure(message: "Add your iPhone first: only it or your Watch can make this change.")
        }
        let rows = Dictionary(uniqueKeysWithValues: model.accessControl.rows.map { ($0.id, $0) })
        return try await device.proposeRules(changes.compactMap { id, rule in
            guard rows[id] != nil else { return nil }
            var change = Agentkeyring_V2_RuleChange()
            change.loginID = id.uuidString
            change.rule = switch rule {
            case .ask, .askOnPhone: .ask
            case .automatic: .automatic
            case .blocked: .blocked
            }
            change.phoneAndWatchOnly = rule == .askOnPhone
            return change
        })
    }

    public func setAutomatic(machineID: String, on: Bool, context: LAContext) async throws {
        guard let device = model.device else { return }
        try await confirmed { try await device.setAutomatic(machineID, allowed: on, context: context) }
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
