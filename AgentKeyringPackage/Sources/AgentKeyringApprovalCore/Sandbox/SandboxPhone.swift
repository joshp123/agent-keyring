// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// The iPhone's screens on a sandbox world: PhoneModel calls this as it calls
// PhoneKeyringEngine. First run moves by PhoneFirstRun's table and adding Apple
// Watch by PhoneAddWatch's, as on the iPhone; Face ID and the relay are
// SandboxEffectRunner's.

import Foundation

extension SandboxWorld: PhoneBackend {
    /// What the iPhone's screens see now.
    public var phoneSnapshot: PhoneSnapshot {
        var snapshot = state.phone
        snapshot.revision = revision
        // As the iPhone lists them: a Blocked login is not also tagged as deleted.
        snapshot.logins = state.logins.map { login in
            PhoneLogin(id: login.id, site: login.site, account: login.account, rule: login.rule, categoryID: login.category.rawValue,
                       asked: login.asked, secretDeleted: login.rule != .blocked && login.secretDeleted,
                       activeLeases: state.requests.filter { $0.loginID == login.id && $0.request.state.isInUse }.count)
        }
        snapshot.requests = state.requests.map(\.request)
        snapshot.devices = state.listed.phoneDevices(readiness: { state.readiness[$0.id] ?? .ready },
                                                     practice: { state.practice[$0.id] })
        return snapshot
    }

    public func phoneSnapshotUpdates() -> AsyncStream<PhoneSnapshot> {
        let source = changes()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { @MainActor [weak self] in
                for await _ in source {
                    guard let self else { break }
                    continuation.yield(self.phoneSnapshot)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func approveAccessRequest(_ requestID: String, reusingUnlock: Bool) async throws {
        if requestID == state.phone.practiceRequest?.id {
            try await effects.runEffect(.approve)
            await sendFirstRunEvent(.practiceEnded(.approved))
            return
        }
        try await approveAccessRequest(requestID, on: .iPhone)
    }

    public func denyAccessRequest(_ requestID: String, reply: String?) async throws {
        if requestID == state.phone.practiceRequest?.id {
            try await effects.runEffect(.deny)
            set { $0.phone.practiceDeniedReply = reply?.isEmpty == true ? nil : reply }
            await sendFirstRunEvent(.practiceEnded(.denied))
            return
        }
        try await denyAccessRequest(requestID, reply: reply, on: .iPhone)
    }

    public func endApprovedAccess(_ requestID: String) async throws { try await stopRequest(requestID) }

    public func setLoginRule(_ rule: LoginRule, forLogin loginID: String) async throws {
        try await setLoginRule(rule, for: [loginID])
    }

    public func setLoginRule(_ rule: LoginRule, forLogins loginIDs: [String]) async throws {
        try await setLoginRule(rule, for: loginIDs)
    }

    public func removeDevice(device deviceID: String) async throws { try await removeDevice(deviceID) }

    public func sendUnsentChanges() async throws {
        try await effects.runEffect(.sendUpdates)
        set { $0.phone.hasUnsentUpdates = false }
    }

    public func sendFirstRunEvent(_ event: PhoneFirstRunEvent) async {
        set { state in
            state.phone.firstRun = state.phone.firstRun.on(event)
            let practiceID = state.phone.firstRun.practiceID
            state.phone.practiceRequest = state.phone.firstRun == .practice(id: practiceID ?? "") ? .practiceAccessRequest(id: practiceID ?? AccessRequest.localPracticeID) : nil
        }
    }

    /// The world's own notification facts: the real iOS settings are never read, and its question never shown.
    public func checkNotifications() async -> PhoneNotificationStatus {
        PhoneNotificationStatus(asked: state.phone.notificationFacts.allowed, facts: state.phone.notificationFacts)
    }

    /// iOS's question, as SandboxEffectRunner says: allowed once it runs, not allowed when it fails or is cancelled.
    public func askForNotifications() async -> Bool {
        do { try await effects.runEffect(.askNotifications) } catch { return false }
        set { state in
            state.phone.notificationFacts.allowed = true
            state.phone.notificationFacts.banners = true
            state.phone.notificationFacts.lockScreen = true
        }
        return true
    }

    /// A practice to this iPhone opens the one waiting; another device's goes to its row.
    public func sendPracticeRequest(to deviceID: String?) async -> String? {
        guard let deviceID else { return state.phone.practiceRequest?.id }
        try? await sendPracticeRequest(toDevice: deviceID)
        return nil
    }

    public func savePhoneSettings(_ settings: PhoneSettings) async { set { $0.phone.settings = settings } }

    public func handleAddWatchTap(_ tap: PhoneAddWatchTap) async {
        let flow = state.phone.addWatch ?? .initialFlow(paired: state.phone.watch.paired, installed: state.phone.watch.installed)
        let next: PhoneAddWatch
        switch tap {
        case .open: next = .initialFlow(paired: state.phone.watch.paired, installed: state.phone.watch.installed)
        case .continueWithFaceID:
            do {
                try await effects.runEffect(.addWatch)
                next = flow.on(.confirmed(until: .now.addingTimeInterval(PhoneAddWatch.hold)))
            } catch {
                next = flow
            }
        case .checkAgain: next = flow.on(.checked(paired: state.phone.watch.paired, installed: state.phone.watch.installed))
        case .tryAgain: next = flow.on(.tryAgain(now: .now))
        case .cancel: next = flow.on(.cancel)
        case .done: next = flow.on(.done)
        }
        set { $0.phone.addWatch = next == .closed ? nil : next }
        if next == .closed, state.phone.firstRun == .addWatch { await sendFirstRunEvent(.done) }
    }

    public func setUpHere() async throws {
        try await effects.runEffect(.setUpHere)
        await sendFirstRunEvent(.setUpHere)
    }

    public func turnOnInPasswords(asking: Bool) async -> Bool {
        if asking { set { $0.phone.passwordsCopy.turnedOn = true } }
        return state.phone.passwordsCopy.turnedOn
    }

    /// The page that adds another computer. Its states have no shared table: these are the iPhone's steps.
    public func handleAddComputerTap(_ tap: PhoneAddComputerTap) async {
        let code = "7K2M-9QXD-4HPR-T3VN-8WBC-6J"
        switch tap {
        case .open, .newCode:
            set { $0.phone.addComputer = .invite(code: code, command: DeviceSheetCopy.enrolCommand(code),
                                                 until: SandboxState.fixedClock().addingTimeInterval(600)) }
        case .approve, .retryDelivery:
            guard case let .asked(name)? = state.phone.addComputer else { return }
            do {
                try await effects.runEffect(.addComputer)
                set { state in
                    state.phone.addComputer = .added(name: name)
                    state.computers.append(SandboxComputer(id: UUID().uuidString, name: name))
                }
            } catch {
                set { $0.phone.addComputer = .failed((error as? LocalizedError)?.errorDescription ?? PhoneCopy.addComputerFailed) }
            }
        case .deny:
            if case let .asked(name)? = state.phone.addComputer { set { $0.phone.addComputer = .notAdded(name: name) } }
        case .close:
            set { $0.phone.addComputer = nil }
        }
    }

    public func answerDeviceJoin(add: Bool) async throws {
        guard case let .asked(name, isMac)? = state.phone.deviceJoin else { return }
        if add { try await effects.runEffect(.answerDeviceJoin) }
        set { state in
            state.phone.deviceJoin = nil
            guard add else { return }
            let id = UUID().uuidString
            state.devices.append(.init(id: id, name: name, kind: isMac ? .mac : .iPhone))
            if isMac { state.computers.append(SandboxComputer(id: id + "-agents", name: name, pairedDeviceID: id)) }
        }
    }

    /// A failed sync leaves the world as it was, as on the iPhone, where Sync Now reports nothing.
    public func syncWithICloudNow() async { try? await sync() }

    public func resetKeyring(includingICloud: Bool) async throws { try await resetSandboxWorld() }
}
