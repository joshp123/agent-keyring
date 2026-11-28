// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// This Mac's keyring as a sandbox bundle, for the screens to run on
// elsewhere with no real secret: its logins as the Passwords tab lists them,
// the devices and computers in its list, and its requests, every password
// "hunter2" and every two-factor seed the test seed.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import AgentKeyringEngine
import AgentKeyringSealing
import Foundation

@available(macOS 26.0, *)
@MainActor
extension AppMainWindowBackend {
    /// What this Mac holds, as a bundle. Nothing is opened: the bundle's passwords are all "hunter2".
    public func sandboxBundle(model: MacKeyringEngine) throws -> Data {
        let shown = snapshot()
        let withCodes = Set(model.leaseLogins.filter { $0.availableFields.contains(.totp) }.map(\.id))
        let logins = shown.logins.map { row in
            SandboxLogin(id: row.id.uuidString, site: row.site, account: row.account, rule: row.rule, category: row.category,
                         asked: row.asked, approved: row.approved, denied: row.denied, secretDeleted: row.secretDeleted,
                         isTestPassword: row.isTestPassword, totpSeed: withCodes.contains(row.id) ? SandboxSecrets.totpSeed : nil)
        }
        let members = model.device?.members
        let devices = (members?.devices ?? []).compactMap { member -> SignedListDevice? in
            let kind: SignedListDeviceKind? = switch member.kind {
            case .iphone: .iPhone
            case .watch: .watch
            case .mac: .mac
            case .unspecified, .UNRECOGNIZED: nil
            }
            return kind.map { .init(id: member.keyID, name: member.label, kind: $0) }
        }
        let computers = (members?.machines ?? []).map { machine in
            SandboxComputer(id: machine.machineID, name: machine.label,
                            pairedDeviceID: members.flatMap { CredentialSealing.pairedMac(machine.machineID, in: $0).sorted().first })
        }
        let loginOf = Dictionary(model.leaseStore.leases.map { ($0.requestID, $0.loginID) }, uniquingKeysWith: { first, _ in first })
        var world = SandboxState(logins: logins, devices: devices, computers: computers, thisDeviceID: model.thisMacDeviceKey,
                                 importedAt: shown.importedAt)
        world.requests = shown.requests.map { SandboxRequest($0, loginID: loginOf[$0.id]) }
        return try SandboxBundleCodec.data(from: world)
    }
}
#endif
