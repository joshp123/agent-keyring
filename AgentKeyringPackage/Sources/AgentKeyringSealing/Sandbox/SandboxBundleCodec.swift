// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// A sandbox world as protobuf (SandboxBundle in keyring.proto), and back.
// Both ways every password becomes "hunter2" and every two-factor seed the
// test seed, whatever the bundle says, so no real secret can travel in one.
// The iPhone's first run is filled in by AgentKeyringEngine/Phone, which
// keeps the one mapping of it to protobuf.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import Foundation

public enum SandboxBundleCodec {
    public static func data(from state: SandboxState) throws -> Data { try bundle(from: state).serializedData() }

    public static func state(from data: Data) throws -> SandboxState {
        state(from: try Agentkeyring_V2_SandboxBundle(serializedBytes: data))
    }

    public static func bundle(from state: SandboxState) -> Agentkeyring_V2_SandboxBundle {
        var bundle = Agentkeyring_V2_SandboxBundle()
        bundle.logins = state.logins.map { login in
            var stored = Agentkeyring_V2_SandboxLogin()
            stored.id = login.id
            stored.site = login.site
            stored.account = login.account
            stored.rule = rule(login.rule)
            stored.category = login.category.rawValue
            stored.asked = UInt32(clamping: login.asked)
            stored.approved = UInt32(clamping: login.approved)
            stored.denied = UInt32(clamping: login.denied)
            stored.secretDeleted = login.secretDeleted
            stored.isTestPassword = login.isTestPassword
            stored.password = SandboxSecrets.password
            stored.totpSeed = login.totpSeed == nil ? "" : SandboxSecrets.totpSeed
            return stored
        }
        bundle.devices = state.devices.map { device in
            var stored = Agentkeyring_V2_SandboxDevice()
            stored.id = device.id
            stored.name = device.name
            stored.kind = switch device.kind {
            case .iPhone: .iphone
            case .watch: .watch
            case .mac: .mac
            }
            return stored
        }
        bundle.computers = state.computers.map { computer in
            var stored = Agentkeyring_V2_SandboxComputer()
            stored.id = computer.id
            stored.name = computer.name
            stored.pairedDeviceID = computer.pairedDeviceID ?? ""
            return stored
        }
        bundle.requests = state.requests.map(request)
        bundle.thisDeviceID = state.thisDeviceID
        if let importedAt = state.importedAt { bundle.importedUnixSeconds = importedAt.timeIntervalSince1970 }
        bundle.watchPaired = state.phone.watch.paired
        bundle.watchInstalled = state.phone.watch.installed
        return bundle
    }

    /// The world a bundle describes, joined and past first run, with nothing waiting on the Mac's own notices.
    public static func state(from bundle: Agentkeyring_V2_SandboxBundle) -> SandboxState {
        let logins = bundle.logins.map { stored in
            SandboxLogin(id: stored.id, site: stored.site, account: stored.account, rule: rule(stored.rule),
                         category: ImportCategory(rawValue: stored.category) ?? .other, asked: Int(stored.asked),
                         approved: Int(stored.approved), denied: Int(stored.denied), secretDeleted: stored.secretDeleted,
                         isTestPassword: stored.isTestPassword, totpSeed: stored.totpSeed.isEmpty ? nil : SandboxSecrets.totpSeed)
        }
        let devices = bundle.devices.compactMap { stored -> SignedListDevice? in
            let kind: SignedListDeviceKind? = switch stored.kind {
            case .iphone: .iPhone
            case .watch: .watch
            case .mac: .mac
            case .unspecified, .UNRECOGNIZED: nil
            }
            return kind.map { .init(id: stored.id, name: stored.name, kind: $0) }
        }
        let computers = bundle.computers.map {
            SandboxComputer(id: $0.id, name: $0.name, pairedDeviceID: $0.pairedDeviceID.isEmpty ? nil : $0.pairedDeviceID)
        }
        var phone = PhoneSnapshot(firstRun: .finished)
        phone.joined = true
        phone.hasComputer = !computers.isEmpty
        phone.macName = devices.first { $0.kind == .mac }?.name
        phone.watch.paired = bundle.watchPaired
        phone.watch.installed = bundle.watchInstalled
        phone.watch.added = devices.contains { $0.kind == .watch }
        let importedAt = bundle.hasImportedUnixSeconds ? Date(timeIntervalSince1970: bundle.importedUnixSeconds) : nil
        phone.passwordsCopy.copiedAt = importedAt
        return SandboxState(logins: logins, devices: devices, computers: computers, thisDeviceID: bundle.thisDeviceID,
                            requests: bundle.requests.compactMap(request), importedAt: importedAt, phone: phone)
    }

    // MARK: Rules and requests

    static func rule(_ rule: LoginRule) -> Agentkeyring_V2_Rule {
        switch rule {
        case .ask: .ask
        case .automatic: .automatic
        case .blocked: .blocked
        }
    }

    static func rule(_ rule: Agentkeyring_V2_Rule) -> LoginRule {
        switch rule {
        case .automatic: .automatic
        case .blocked: .blocked
        case .ask, .unspecified, .UNRECOGNIZED: .ask
        }
    }

    static func request(_ sandboxed: SandboxRequest) -> Agentkeyring_V2_SandboxRequest {
        let request = sandboxed.request
        var stored = Agentkeyring_V2_SandboxRequest()
        stored.id = request.id
        stored.loginID = sandboxed.loginID ?? ""
        stored.site = request.login.site
        stored.account = request.login.account
        stored.agent = request.agent.name
        stored.machine = request.agent.machine
        stored.project = request.agent.project ?? ""
        stored.folder = request.agent.folder ?? ""
        stored.reason = request.agentReason
        stored.askedUnixSeconds = request.askedAt.timeIntervalSince1970
        stored.byAutomaticRule = request.byAutomaticRule
        stored.isLocal = request.agent.isLocal
        func at(_ date: Date?) { stored.stateUnixSeconds = date?.timeIntervalSince1970 ?? 0 }
        switch request.state {
        case let .waitingForYou(until): stored.state = .waiting; at(until)
        // An answer still on its way is dumped as still waiting: the sandbox has no relay to finish it.
        case .sendingAnswer, .waitingForMac: stored.state = .waiting; at(request.askedAt.addingTimeInterval(600))
        case let .approved(by, until): stored.state = .approved; stored.answeredOn = by.rawValue; at(until)
        case let .denied(by, reply, askAgainAfter): stored.state = .denied; stored.answeredOn = by.rawValue; stored.reply = reply ?? ""; at(askAgainAfter)
        case .unanswered: stored.state = .unanswered
        case .cancelled: stored.state = .cancelled
        case let .expired(date): stored.state = .expired; at(date)
        case let .released(date): stored.state = .released; at(date)
        case let .ended(date): stored.state = .ended; at(date)
        case .blockedByRule: stored.state = .blockedByRule
        }
        return stored
    }

    static func request(_ stored: Agentkeyring_V2_SandboxRequest) -> SandboxRequest? {
        let at = Date(timeIntervalSince1970: stored.stateUnixSeconds)
        let surface = ApprovalSurface(rawValue: stored.answeredOn) ?? .mac
        let state: AccessRequestState
        switch stored.state {
        case .waiting: state = .waitingForYou(until: at)
        case .approved: state = .approved(by: surface, until: at)
        case .denied: state = .denied(by: surface, reply: stored.reply.isEmpty ? nil : stored.reply,
                                      askAgainAfter: stored.stateUnixSeconds > 0 ? at : nil)
        case .unanswered: state = .unanswered
        case .cancelled: state = .cancelled
        case .expired: state = .expired(at: at)
        case .released: state = .released(at: at)
        case .ended: state = .ended(at: at)
        case .blockedByRule: state = .blockedByRule
        case .unspecified, .UNRECOGNIZED: return nil
        }
        let request = AccessRequest(
            id: stored.id, login: RequestedLogin(site: stored.site, account: stored.account),
            agent: RequestingAgent(name: stored.agent, machine: stored.machine, address: "",
                                   folder: stored.folder.isEmpty ? nil : stored.folder,
                                   project: stored.project.isEmpty ? nil : stored.project, isLocal: stored.isLocal),
            access: .login, agentReason: stored.reason, askedAt: Date(timeIntervalSince1970: stored.askedUnixSeconds),
            state: state, byAutomaticRule: stored.byAutomaticRule)
        return SandboxRequest(request, loginID: stored.loginID.isEmpty ? nil : stored.loginID)
    }
}
