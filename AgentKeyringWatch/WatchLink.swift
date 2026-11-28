// Written by AI on 2026.11.18 by model claude opus 5.5; hardened WatchConnectivity concurrency, I/O isolation and multi-transport Add on 2026.11.25 by model gemini-4-neon.
// Transport split on 2026.11.27 by model GPT-6.2 Sol.

import AgentKeyringProtocol
import AgentKeyringSealing
import AgentKeyringWatchUI
import Foundation
import LocalAuthentication
import UserNotifications
import WatchConnectivity


final class WatchLink: NSObject, @unchecked Sendable {
    static let shared = WatchLink()

    nonisolated private static let pbKey = "pb"
    nonisolated private static let resetAtKey = "resetAtUnixSeconds"
    private let ioQueue = DispatchQueue(label: "com.joshpalmer.AgentKeyring.Watch.io", qos: .userInitiated)
    private let lock = NSLock()
    private let state = WatchStateCoordinator(log: .watch)
    private var _pushToken: Data?
    private var _lastProblem: String?
    private var _refreshGeneration: UInt64 = 0
    private var _pullInFlight = false
    private var handOverSchedule = WatchStateCoordinator.HandOverSchedule()
    private var _lastForegroundAt: Date = .distantPast
    private var idle: [() -> Void] = []

    private static func encode(_ message: Agentkeyring_V2_WatchToPhone) -> [String: Any] {
        guard let data = try? message.serializedData() else { return [:] }
        return [pbKey: data]
    }

    private static func decode(_ payload: [String: Any]) -> Agentkeyring_V2_PhoneToWatch? {
        guard let data = payload[pbKey] as? Data else { return nil }
        return try? Agentkeyring_V2_PhoneToWatch(serializedBytes: data)
    }

    private static func isAddWatchTransfer(_ userInfo: [String: Any]) -> Bool {
        guard let data = userInfo[pbKey] as? Data else { return false }
        return (try? Agentkeyring_V2_WatchToPhone(serializedBytes: data))?.addWatch == true
    }

    var pushToken: Data? {
        get { lock.withLock { _pushToken } }
        set { lock.withLock { _pushToken = newValue } }
    }
    var lastProblem: String? {
        get { lock.withLock { _lastProblem } }
        set { lock.withLock { _lastProblem = newValue } }
    }

    private func runIO<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in
            ioQueue.async { done.resume(returning: work()) }
        }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate == nil { session.delegate = self }
        if session.activationState != .activated { session.activate() }
    }

    private func waitForSession(checks: Int, reachable: Bool = false) async {
        activate()
        let session = WCSession.default
        for _ in 0..<checks {
            if session.activationState == .activated && (!reachable || session.isReachable) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func onForeground() {
        let shouldRun: Bool = lock.withLock {
            let now = Date()
            guard now.timeIntervalSince(_lastForegroundAt) > 0.5 else { return false }
            _lastForegroundAt = now
            return true
        }
        guard shouldRun else { return }
        activate()
        Task {
            if WCSession.default.activationState == .activated {
                await self.runIO {
                    if let message = Self.decode(WCSession.default.receivedApplicationContext) {
                        self.receive(message, current: true)
                    }
                }
            }
            await self.refreshSetup()
            Task { await self.pullLatestFromPhone() }
            Task { await self.sendHandOver() }
        }
    }

    /// Runs `done` once nothing more is waiting to arrive from the iPhone.
    func whenIdle(_ done: @escaping () -> Void) {
        let session = WCSession.default
        if session.activationState == .activated, !session.hasContentPending { done(); return }
        lock.withLock { idle.append(done) }
    }

    private func drainIdle() {
        let waiting = lock.withLock { () -> [() -> Void] in
            guard !WCSession.default.hasContentPending else { return [] }
            defer { idle = [] }
            return idle
        }
        waiting.forEach { $0() }
    }

    func sendHandOver(force: Bool = false) async {
        guard WCSession.default.activationState == .activated else { return }
        guard lock.withLock({ handOverSchedule.begin(force: force) }) else { return }
        while true {
            let selfTest = await runSelfTest()
            await runIO {
                let handOver = self.state.handOver(selfTest: selfTest, pushToken: self.pushToken)
                if let problem = handOver.keyError { self.lastProblem = problem }
                do {
                    try WCSession.default.updateApplicationContext(Self.encode(handOver.message))
                } catch {
                    log.error("context: \(error.localizedDescription, privacy: .public)")
                    KeyringDiagnosticLog.watch.noteDeviceEvent("watchlink", "handover context failed", ["error": "\(error)"])
                }
            }
            if !lock.withLock({ handOverSchedule.finish() }) { return }
        }
    }

    func sendDismissRequest(_ id: String) {
        guard !id.isEmpty, WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        sendDurably(WatchStateCoordinator.dismissRequest(id), on: session)
    }

    private func sendDurably(_ message: Agentkeyring_V2_WatchToPhone, on session: WCSession) {
        let payload = Self.encode(message)
        if session.isReachable { session.sendMessage(payload, replyHandler: nil, errorHandler: nil) }
        session.transferUserInfo(payload)
    }

    func report(problem: String) {
        KeyringDiagnosticLog.watch.noteDeviceEvent("app", "problem", ["msg": problem])
        lastProblem = problem
        log.error("\(problem, privacy: .public)")
        Task { await sendHandOver(force: true) }
    }

    private func checkOnWristWithTimeout(timeout: Duration = .seconds(2)) async -> Bool {
        await withCheckedContinuation { done in
            let gate = OneShotContinuation(done)
            Task {
                try? await Task.sleep(for: timeout)
                gate.resume(false)
            }
            ioQueue.async {
                let context = LAContext()
                context.interactionNotAllowed = true
                context.evaluatePolicy(.deviceOwnerAuthenticationWithWristDetection, localizedReason: "Check") { ok, _ in
                    gate.resume(ok)
                }
            }
        }
    }
    private static func passcodeIsSet() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    private func runSelfTest() async -> Agentkeyring_V2_WatchSelfTest {
        let onWrist = await checkOnWristWithTimeout()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let notificationsAllowed = settings.authorizationStatus == .authorized
        let timeSensitiveAllowed = settings.timeSensitiveSetting == .enabled
        return await runIO {
            self.state.selfTest(passcode: Self.passcodeIsSet(), onWrist: onWrist,
                                notificationsAllowed: notificationsAllowed, timeSensitiveAllowed: timeSensitiveAllowed,
                                hasPushToken: self.pushToken != nil, problem: self.lastProblem)
        }
    }

    // Called on ioQueue, including all WatchConnectivity delegate deliveries.
    private func receive(_ message: Agentkeyring_V2_PhoneToWatch, current: Bool) {
        let update = state.receive(message, current: current)
        updateAfterReceive(addUntil: update.addUntil, removed: update.removed)
    }

    private func updateAfterReceive(addUntil: Date?, removed: Bool) {
        if removed { lastProblem = nil }
        if let addUntil, addUntil > .now {
            Task {
                try? await Task.sleep(for: .seconds(addUntil.timeIntervalSinceNow + 1))
                await self.refreshSetup()
            }
        }
    }

    private func sendMessageWithTimeout(_ message: Agentkeyring_V2_WatchToPhone, timeout: Duration = .seconds(8)) async -> Agentkeyring_V2_PhoneToWatch? {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return nil }
        let encoded = Self.encode(message)
        return await withCheckedContinuation { done in
            let gate = OneShotContinuation(done)
            Task {
                try? await Task.sleep(for: timeout)
                gate.resume(nil)
            }
            session.sendMessage(encoded, replyHandler: { reply in
                gate.resume(Self.decode(reply))
            }, errorHandler: { error in
                KeyringDiagnosticLog.watch.noteDeviceEvent("watchlink", "sendMessage failed", ["error": "\(error)"])
                gate.resume(nil)
            })
        }
    }

    func pullLatestFromPhone() async {
        let shouldStart: Bool = lock.withLock {
            guard !_pullInFlight else { return false }
            _pullInFlight = true
            return true
        }
        guard shouldStart else { return }
        defer { lock.withLock { _pullInFlight = false } }

        let session = WCSession.default
        await waitForSession(checks: 20)
        guard session.activationState == .activated, session.isReachable else { return }
        let request = await runIO { self.state.membersRequest().request }
        guard let reply = await sendMessageWithTimeout(request, timeout: .seconds(5)) else { return }
        await runIO { self.receive(reply, current: true) }
        await refreshSetup()
    }

    func add() async -> Bool {
        let session = WCSession.default
        KeyringDiagnosticLog.watch.noteDeviceEvent("setup", "add tapped", ["activation": "\(session.activationState.rawValue)", "reachable": "\(session.isReachable)"])
        guard let offerID = await runIO({ self.state.beginAdd() }) else {
            KeyringDiagnosticLog.watch.noteDeviceEvent("setup", "add failed", ["reason": "no active offer"])
            await refreshSetup()
            return false
        }
        await refreshSetup()

        await waitForSession(checks: 20)
        guard session.activationState == .activated else {
            KeyringDiagnosticLog.watch.noteDeviceEvent("setup", "add failed", ["reason": "session not activated"])
            return await addFailed(offerID: offerID)
        }

        let prepared: (request: Agentkeyring_V2_WatchToPhone, keyID: String)
        do {
            guard let queued = try await runIO({ self.queueAdd(offerID: offerID) }).get() else {
                await refreshSetup()
                return true
            }
            prepared = queued
        } catch {
            lastProblem = "The Watch could not make its keys: \(error)"
            KeyringDiagnosticLog.watch.noteDeviceEvent("setup", "add failed", ["reason": "\(error)"])
            return await addFailed(offerID: offerID)
        }

        let deadline = Date().addingTimeInterval(10)
        var triedLiveMessage = false
        while Date() < deadline {
            switch await runIO({ self.state.addProgress(offerID: offerID, keyID: prepared.keyID) }) {
            case .accepted: return await addAccepted(via: "background")
            case .cancelled: return true
            case .waiting: break
            }
            if !triedLiveMessage, session.isReachable {
                triedLiveMessage = true
                let remaining = max(1.5, min(6.0, deadline.timeIntervalSinceNow))
                if let reply = await sendMessageWithTimeout(prepared.request, timeout: .seconds(remaining)) {
                    await runIO { self.receive(reply, current: true) }
                    if reply.hasAccepted, !reply.accepted {
                        KeyringDiagnosticLog.watch.noteDeviceEvent("setup", "add rejected", [:])
                        return await addFailed(offerID: offerID)
                    }
                    return await addAccepted(via: "live")
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        switch await runIO({ self.state.addProgress(offerID: offerID, keyID: prepared.keyID) }) {
        case .accepted: return await addAccepted(via: "background-late")
        case .cancelled: return true
        case .waiting: break
        }
        KeyringDiagnosticLog.watch.noteDeviceEvent("setup", "add failed", ["reason": triedLiveMessage ? "reply timed out" : "iphone not reachable",
                                           "reachable": "\(session.isReachable)"])
        await runIO {
            self.state.clearAdd(offerID: offerID)
            self.replaceAddTransfer(with: self.state.cancelMessage(offerID: offerID), on: WCSession.default)
        }
        Task { await self.sendHandOver(force: true) }
        await refreshSetup()
        return false
    }

    private func queueAdd(offerID: String) -> Result<(Agentkeyring_V2_WatchToPhone, String)?, Error> {
        Result {
            let prepared = try state.prepareAdd(offerID: offerID, pushToken: pushToken)
            // Check for cancellation on the same queue as the transfer.
            guard state.isSendingAdd(offerID: offerID) else { return nil }
            let session = WCSession.default
            do {
                try session.updateApplicationContext(Self.encode(prepared.context))
            } catch {
                log.error("add context: \(error.localizedDescription, privacy: .public)")
                KeyringDiagnosticLog.watch.noteDeviceEvent("setup", "add context failed", ["error": "\(error)"])
            }
            replaceAddTransfer(with: prepared.request, on: session)
            return (prepared.request, prepared.keyID)
        }
    }

    private func addAccepted(via route: String) async -> Bool {
        KeyringDiagnosticLog.watch.noteDeviceEvent("setup", "add accepted", ["via": route])
        await refreshSetup()
        Task { await self.sendHandOver(force: true) }
        return true
    }

    private func addFailed(offerID: String) async -> Bool {
        await runIO { self.state.clearAdd(offerID: offerID) }
        await refreshSetup()
        return false
    }

    private func replaceAddTransfer(with message: Agentkeyring_V2_WatchToPhone, on session: WCSession) {
        for transfer in session.outstandingUserInfoTransfers where Self.isAddWatchTransfer(transfer.userInfo) {
            transfer.cancel()
        }
        session.transferUserInfo(Self.encode(message))
    }

    func cancelAdd() async {
        let cancel = await runIO { self.state.cancelAdd() }
        KeyringDiagnosticLog.watch.noteDeviceEvent("setup", "add cancelled", [:])
        await refreshSetup()
        let session = WCSession.default
        guard session.activationState == .activated, let cancel else { return }
        if let reply = await sendMessageWithTimeout(cancel, timeout: .seconds(5)) {
            await runIO { self.receive(reply, current: true) }
            await refreshSetup()
            if !reply.cancelled {
                KeyringDiagnosticLog.watch.noteDeviceEvent("setup", "cancel refused by iPhone", ["reason": "upload already in flight or offer ended"])
            }
            Task { await self.sendHandOver(force: true) }
            return
        }
        await runIO { self.replaceAddTransfer(with: cancel, on: WCSession.default) }
        Task { await self.sendHandOver(force: true) }
    }
}

extension WatchLink: WCSessionDelegate {
    func askForPractice() async -> Bool {
        await waitForSession(checks: 30, reachable: true)
        guard WCSession.default.isReachable else { return false }
        let asked = await sendMessageWithTimeout(WatchStateCoordinator.practiceRequest(), timeout: .seconds(10))?.asked ?? false
        KeyringDiagnosticLog.watch.noteDeviceEvent("practice", asked ? "asked" : "not asked", [:])
        if asked {
            await runIO { self.state.practiceRequested() }
            Task { try? await Task.sleep(for: .seconds(WatchOnboardingStep.practiceWait + 1)); await self.refreshSetup() }
        }
        await refreshSetup()
        return asked
    }

    func cancelPractice() async {
        await runIO { self.state.cancelPractice() }
        await refreshSetup()
    }

    func practiceOfferDone() async {
        await runIO { self.state.practiceOfferDone() }
        await refreshSetup()
    }

    static func makeSetup(saved: WatchPersistedState, notifications: WatchNotificationPermission, hasPushToken: Bool) -> WatchOnboardingStep {
        shared.state.makeSetup(saved: saved, notifications: notifications, hasPushToken: hasPushToken,
                               passcode: passcodeIsSet())
    }

    /// Uses a monotonic generation so an older async notificationSettings() lookup never overwrites newer state.
    func refreshSetup() async {
        let generation: UInt64 = lock.withLock {
            _refreshGeneration &+= 1
            return _refreshGeneration
        }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let notifications: WatchNotificationPermission = status == .notDetermined ? .notAsked : status == .denied ? .denied : .allowed
        let snapshot = await runIO {
            self.state.setupSnapshot(notifications: notifications, hasPushToken: self.pushToken != nil,
                                     passcode: Self.passcodeIsSet())
        }
        await MainActor.run {
            let isLatest = self.lock.withLock { self._refreshGeneration == generation }
            guard isLatest else { return }
            WatchModel.shared.setup = snapshot.setup
            WatchModel.shared.inUse = snapshot.inUse
        }
    }

    func stop(_ id: String) async -> WatchStopResult {
        await waitForSession(checks: 30, reachable: true)
        guard WCSession.default.isReachable else { return .failed }
        let reply = await sendMessageWithTimeout(WatchStateCoordinator.stopRequest(id), timeout: .seconds(10))
        let result: WatchStopResult = reply?.stopped == true ? .stopped : reply?.stopSent == true ? .sent : .failed
        KeyringDiagnosticLog.watch.noteDeviceEvent("stop", "\(result)", ["request": id])
        if result == .stopped {
            await runIO { self.state.removeInUse(id) }
            await refreshSetup()
        }
        return result
    }

    func askForMembers() async -> Bool {
        let session = WCSession.default
        await waitForSession(checks: 30)
        guard session.activationState == .activated else { return false }
        let (before, request) = await runIO { self.state.membersRequest() }
        await runIO { _ = WCSession.default.transferUserInfo(Self.encode(request)) }
        for _ in 0..<30 where !session.isReachable { try? await Task.sleep(for: .milliseconds(100)) }
        guard session.isReachable else { return false }
        guard let reply = await sendMessageWithTimeout(request, timeout: .seconds(8)) else { return false }
        let changed = await runIO {
            self.receive(reply, current: true)
            return self.state.savedState() != before
        }
        await refreshSetup()
        return changed
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return drainIdle() }
        applyContext(session.receivedApplicationContext)
        Task {
            await self.refreshSetup()
            self.drainIdle()
            Task { await self.pullLatestFromPhone() }
            Task { await self.sendHandOver() }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { await self.pullLatestFromPhone() }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        applyContext(applicationContext)
        refreshAndDrain()
    }

    private func applyContext(_ payload: [String: Any]) {
        guard let message = Self.decode(payload) else { return }
        ioQueue.sync { receive(message, current: true) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receivePayload(userInfo, current: false)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receivePayload(message, current: true)
    }

    private func receivePayload(_ payload: [String: Any], current: Bool) {
        guard let message = Self.decode(payload) else {
            if !current { drainIdle() }
            return
        }
        let id = message.dismissRequestID
        if id.isEmpty {
            ioQueue.sync { receive(message, current: current) }
            refreshAndDrain(drain: !current)
        } else {
            Task {
                KeyringDiagnosticLog.watch.noteDeviceEvent("notification", "removed", ["request": id, "by": "iphone"])
                await WatchDelegate.removeDeliveredNotification(id: id)
                await MainActor.run {
                    WatchModel.shared.markRequestHandled(id)
                    WatchModel.shared.dismissForegroundRequest(id: id)
                }
                if !current { self.drainIdle() }
            }
        }
    }

    private func refreshAndDrain(drain: Bool = true) {
        Task {
            await self.refreshSetup()
            if drain { self.drainIdle() }
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        defer { Task { self.drainIdle() } }
        guard let data = file.metadata?[Self.pbKey] as? Data,
              let metadata = try? Agentkeyring_V2_WatchFileMetadata(serializedBytes: data) else {
            KeyringDiagnosticLog.watch.noteDeviceEvent("transfer", "unreadable metadata", [:])
            return
        }
        // WatchConnectivity removes the file once the delegate returns.
        let contents = try? Data(contentsOf: file.fileURL)
        let resetAt = file.metadata?[Self.resetAtKey] as? Double ?? 0
        let receipt = ioQueue.sync {
            let receipt = state.receiveFile(contents, metadata: metadata, resetAt: resetAt)
            updateAfterReceive(addUntil: receipt.addUntil, removed: receipt.removed)
            return receipt
        }
        if let message = receipt.response { sendDurably(message, on: session) }
        if receipt.refreshSetup {
            Task {
                await self.refreshSetup()
                if receipt.handOver { await self.sendHandOver(force: true) }
            }
        }
    }
}

private final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
