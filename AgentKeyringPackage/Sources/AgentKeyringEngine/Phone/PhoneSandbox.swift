// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// This iPhone's keyring as a sandbox bundle, for the screens to run on
// elsewhere with no real secret: its logins, devices, computers, requests
// and where first run stands, every password "hunter2". And a bundle read
// back, first run included.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation

@MainActor
extension PhoneKeyringEngine {
    /// What this iPhone holds, as a bundle. Its passwords never leave sealed: the bundle carries "hunter2".
    public func sandboxBundle() throws -> Data {
        let snapshot = self.snapshot
        let members = self.members
        let envelopes = state.requestEnvelopes.values.compactMap { try? Agentkeyring_V2_SignedRequestEnvelope(serializedBytes: $0) }
        let loginOf = Dictionary(envelopes.compactMap { envelope in (try? CredentialSealing.parseRequest(envelope.request)).map { ($0.requestID, $0.loginID) } },
                                 uniquingKeysWith: { first, _ in first })
        let logins = (catalogue?.logins ?? []).map { login in
            let shown = snapshot.logins.first { $0.id == login.loginID }
            return SandboxLogin(id: login.loginID, site: Self.site(login), account: login.account, rule: Self.rule(login),
                                category: shown?.categoryID.flatMap(ImportCategory.init(rawValue:)) ?? .other,
                                secretDeleted: login.rule == .blocked || login.version == 0,
                                totpSeed: login.hasOneTimeCode_p ? SandboxSecrets.totpSeed : nil)
        }
        let listed = members.map { Self.listed($0, thisDeviceID: state.deviceKeyID) }
        let computers = (members?.machines ?? []).map { machine in
            SandboxComputer(id: machine.machineID, name: machine.label,
                            pairedDeviceID: members.flatMap { CredentialSealing.pairedMac(machine.machineID, in: $0).sorted().first })
        }
        var world = SandboxState(logins: logins, devices: listed?.approvers.map(\.device) ?? [], computers: computers,
                                 thisDeviceID: state.deviceKeyID ?? "", importedAt: passwordsCopyFacts.copiedAt)
        world.requests = snapshot.requests.map { SandboxRequest($0, loginID: loginOf[$0.id]) }
        world.phone.watch = snapshot.watch
        var bundle = SandboxBundleCodec.bundle(from: world)
        bundle.phoneFirstRun = firstRun.storedProto()
        return try bundle.serializedData()
    }

    /// A bundle as a world for the iPhone's screens, with first run where the bundle left it.
    public nonisolated static func sandboxState(from data: Data) throws -> SandboxState {
        let bundle = try Agentkeyring_V2_SandboxBundle(serializedBytes: data)
        var state = SandboxBundleCodec.state(from: bundle)
        if bundle.hasPhoneFirstRun, let firstRun = PhoneFirstRun(storedProto: bundle.phoneFirstRun) { state.phone.firstRun = firstRun }
        return state
    }
}
