// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// The Mac's screens on a sandbox world: the main window, the menu bar window,
// the request panel and the questions beside the window each call one of
// these as they call the app's own backends. What the Mac shows is read from
// the world each time; Touch ID is SandboxEffectRunner's.

#if os(macOS)
import AgentKeyringApprovalCore
import Foundation

extension SandboxState {
    /// The Mac the Mac's screens run as.
    var thisMac: SignedListDevice { this(.mac) ?? .init(id: "this-mac", name: "Mac", kind: .mac) }

    /// A request from this Mac's own agents is local.
    func onTheMac(_ request: AccessRequest) -> AccessRequest {
        let own = Set(computers.filter { $0.pairedDeviceID == thisMac.id }.map(\.name))
        var request = request
        if own.contains(request.agent.machine) { request.agent.isLocal = true }
        return request
    }

    /// What the main window shows.
    public var macSnapshot: MainSnapshot {
        let logins = logins.map { login in
            let live = requests.filter { $0.loginID == login.id && $0.request.state.isInUse }
            return LoginRow(id: UUID(sandboxID: login.id), site: login.site, account: login.account, rule: login.rule, category: login.category,
                            asked: login.asked, approved: login.approved, denied: login.denied, isTestPassword: login.isTestPassword,
                            secretDeleted: login.secretDeleted, activeLeases: live.count,
                            automaticLeases: live.filter(\.request.byAutomaticRule).count)
        }
        let mac = thisMac
        let thisRow = ApproverRow(id: mac.id, kind: .thisMac, name: mac.name, practice: practice[mac.id],
                                  canPractise: self.mac.canApprove && practice[mac.id]?.isUnderWay != true,
                                  readiness: self.mac.canApprove ? .ready : .unavailable)
        let listed = listed
        var notices: [DevicesNotice] = []
        if self.mac.signedOutOfICloud { notices.append(.noICloud) }
        if self.mac.noPushKey { notices.append(.noPushKey) }
        return MainSnapshot(
            logins: logins, importedAt: importedAt, sampleOnly: self.mac.sampleOnly,
            approvers: listed.macApprovers(thisMac: thisRow, readiness: { readiness[$0.id] ?? .ready }, practice: { practice[$0.id] }),
            computers: listed.computers.map { ComputerRow(id: $0.id, name: $0.name) }, notices: notices,
            unsentChanges: self.mac.unsentChanges, copyChangedNothing: self.mac.copyChangedNothing, copyIsStale: self.mac.copyIsStale,
            remindsToUpdate: self.mac.remindsToUpdate, opensAtLogin: self.mac.opensAtLogin,
            anonymousTelemetry: self.mac.anonymousTelemetry, requests: requests.map { onTheMac($0.request) }, enrolments: enrolments)
    }

    /// What the menu bar window shows.
    public var menuSnapshot: MacMenuBarSnapshot {
        MacMenuBarSnapshot(requests: requests.map { onTheMac($0.request) }, enrolments: enrolments, passwordCount: logins.count)
    }

    /// The login a Mac row stands for.
    func loginID(_ row: UUID) -> String? { logins.first { UUID(sandboxID: $0.id) == row }?.id }
}

extension UUID {
    /// The login's own id when it is a UUID (the Mac's always are), else one made from it the same way each time.
    init(sandboxID: String) {
        if let parsed = UUID(uuidString: sandboxID) { self = parsed; return }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in sandboxID.utf8.enumerated() {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            bytes[index % 16] ^= UInt8(truncatingIfNeeded: hash >> 24)
        }
        self = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// The main window on a sandbox world.
@MainActor
public final class SandboxMainBackend: MainWindowBackend {
    public let world: SandboxWorld
    public init(_ world: SandboxWorld) { self.world = world }

    public func mainWindowSnapshotUpdates() -> AsyncStream<MainSnapshot> { follow(world) { $0.macSnapshot } }

    public func saveLoginRules(_ changes: [UUID: LoginRule]) async throws {
        for rule in LoginRule.allCases {
            let ids = changes.filter { $0.value == rule }.keys.compactMap(world.state.loginID)
            if !ids.isEmpty { try await world.setLoginRule(rule, for: ids) }
        }
    }

    public func removeDevice(id: String) async throws { try await world.removeDevice(id) }
    public func renameDevice(id: String, to newName: String) async throws { try await world.renameDevice(id, to: newName) }
    public func cancelAuthentication() { world.effects.cancelEffect(.setRule); world.effects.cancelEffect(.removeDevice); world.effects.cancelEffect(.renameDevice) }
    /// Opens selective import in the app; the sandbox has no Apple Passwords to read, so only the effect runs.
    public func importAgain() { Task { try? await world.effects.runEffect(.importAgain) } }

    public func addManualPassword(website: String, account: String, password: String, totpSecret: String?, rule: LoginRule) async throws {
        try await world.addPassword(site: website, account: account, rule: rule, totpSeed: totpSecret)
    }

    public func sendPracticeRequest(deviceID: String) { Task { try? await world.sendPracticeRequest(toDevice: deviceID) } }

    public func sendUnsentChanges() async throws {
        try await world.effects.runEffect(.sendUpdates)
        world.set { $0.mac.unsentChanges = 0 }
    }

    public func setPasswordCopyReminder(_ on: Bool) { world.set { $0.mac.remindsToUpdate = on } }
    public func setOpensAtLogin(_ on: Bool) { world.set { $0.mac.opensAtLogin = on } }
    public func setAnonymousTelemetry(_ on: Bool) { world.set { $0.mac.anonymousTelemetry = on } }
    public func syncWithICloudNow() { Task { try? await world.sync() } }
    public func resetKeyring(includingICloud: Bool) async throws { try await world.resetSandboxWorld() }
    public func approveAccessRequest(id: String) async throws { try await world.approveAccessRequest(id, on: .mac) }
    public func denyAccessRequest(id: String, reply: String?) async throws { try await world.denyAccessRequest(id, reply: reply, on: .mac) }

    public func approveEnrolment(id: String) async throws {
        try await world.effects.runEffect(.answerDeviceJoin)
        world.set { state in
            guard let enrolment = state.enrolments.first(where: { $0.id == id }) else { return }
            state.enrolments.removeAll { $0.id == id }
            switch enrolment.kind {
            case .machine: state.computers.append(SandboxComputer(id: enrolment.id, name: enrolment.name))
            case .approver: state.devices.append(.init(id: enrolment.id, name: enrolment.name, kind: .iPhone))
            }
        }
    }

    public func denyEnrolment(id: String) async throws { world.set { $0.enrolments.removeAll { $0.id == id } } }
}

/// The menu bar window on a sandbox world.
@MainActor
public final class SandboxMenuBackend: MacMenuBarBackend {
    public let world: SandboxWorld
    public init(_ world: SandboxWorld) { self.world = world }

    public func menuBarSnapshotUpdates() -> AsyncStream<MacMenuBarSnapshot> { follow(world) { $0.menuSnapshot } }
    public func endApprovedAccess(requestID: String) async throws -> AccessRequestState { try await world.stopRequest(requestID) }
    public func allowAskingAgain(requestID: String) async throws -> AccessRequestState { try await world.allowAskingAgain(requestID) }
    public func approveAccessRequest(requestID: String) async throws -> AccessRequestState { try await world.approveAccessRequest(requestID, on: .mac) }
    public func denyAccessRequest(requestID: String, reply: String?) async throws -> AccessRequestState {
        try await world.denyAccessRequest(requestID, reply: reply, on: .mac)
    }
}

/// The request panel on a sandbox world.
@MainActor
public final class SandboxPanelBackend: MacApprovalBackend {
    public let world: SandboxWorld
    public init(_ world: SandboxWorld) { self.world = world }

    public func accessRequestUpdates(requestID: String) -> AsyncStream<AccessRequest> {
        let source = world.changes()
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await state in source {
                    guard let request = state.requests.first(where: { $0.id == requestID })?.request else { continue }
                    continuation.yield(state.onTheMac(request))
                    if !request.state.isWaitingForYou && !request.state.isInUse { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func approveAccessRequest(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState {
        try await world.effects.runEffect(.ownerApproval)
        onAuthenticated()
        return try await world.approveAccessRequest(requestID, on: .mac)
    }

    public func cancelAuthentication(requestID: String) { world.effects.cancelEffect(.ownerApproval) }
    public func denyAccessRequest(requestID: String, reply: String?) async throws -> AccessRequestState {
        try await world.denyAccessRequest(requestID, reply: reply, on: .mac)
    }
    public func allowAskingAgain(requestID: String) async throws -> AccessRequestState { try await world.allowAskingAgain(requestID) }
}

/// A question beside the window on a sandbox world: Touch ID is the world's `ownerApproval` effect.
@MainActor
public final class SandboxOwnerAuthentication: OwnerAuthentication {
    private let world: SandboxWorld
    private let perform: @MainActor () async throws -> Void
    private var invalidated = false

    public init(_ world: SandboxWorld, perform: @escaping @MainActor () async throws -> Void = {}) {
        self.world = world
        self.perform = perform
    }

    public var canAsk: Bool { world.state.mac.canApprove && !invalidated }

    public func evaluate(reason: String) async throws -> Bool {
        try await world.effects.runEffect(.ownerApproval)
        return !invalidated
    }

    public func performApproved() async throws { try await perform() }

    public func invalidate() {
        invalidated = true
        world.effects.cancelEffect(.ownerApproval)
    }
}

/// Each change to the world, as one screen's snapshot.
@MainActor
private func follow<Snapshot: Sendable>(_ world: SandboxWorld, _ read: @escaping @MainActor (SandboxState) -> Snapshot) -> AsyncStream<Snapshot> {
    let source = world.changes()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        let task = Task { @MainActor in
            for await state in source { continuation.yield(read(state)) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
#endif
