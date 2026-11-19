// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The one hand-over between the Watch and its iPhone, over Watch
// Connectivity. The Watch sends its keys, its push address and what its
// self-test found; the iPhone sends the signed Members and Catalogue and the
// relay's address for answers. Each side sends with both transferUserInfo and
// updateApplicationContext, so it arrives whichever app runs first.

import AgentKeyringProtocol
import AgentKeyringSealing
import AgentKeyringWatchCore
import CryptoKit
import Foundation
import LocalAuthentication
import UserNotifications
import WatchConnectivity

final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchLink()

    private let lock = NSLock()
    private var _pushToken: Data?
    private var _lastProblem: String?
    private var idle: [() -> Void] = []

    var pushToken: Data? {
        get { lock.withLock { _pushToken } }
        set { lock.withLock { _pushToken = newValue } }
    }
    var lastProblem: String? {
        get { lock.withLock { _lastProblem } }
        set { lock.withLock { _lastProblem = newValue } }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate == nil { session.delegate = self }
        if session.activationState != .activated { session.activate() }
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

    // MARK: Sending

    /// The Watch's keys, push address and self-test, for the iPhone to add it.
    func sendHandOver() async {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let keys = WatchKeys()
        var payload: [String: Any] = ["watchSelfTest": await selfTest(keys)]
        do {
            payload["watchDevice"] = try keys.device().serializedData()
            if let token = pushToken {
                var push = Agentkeyring_V2_PushRegistration()
                push.deviceKeyID = try keys.keyID()
                push.apnsToken = token
                push.apnsTopic = Bundle.main.bundleIdentifier ?? ""
                push.apnsProduction = PushEnvironment.isProduction
                push.noticePublicKey = try keys.noticePublicKey()
                payload["watchPush"] = try push.serializedData()
            }
        } catch {
            lastProblem = "The Watch could not make its keys: \(error)"
        }
        do { try session.updateApplicationContext(payload) } catch { log.error("context: \(error.localizedDescription, privacy: .public)") }
        session.transferUserInfo(payload)
    }

    /// A problem the person sees as one plain line; the detail goes to the iPhone, which reports it.
    func report(problem: String) {
        lastProblem = problem
        log.error("\(problem, privacy: .public)")
        Task { await sendHandOver() }
    }

    /// What the Watch can find out about itself, with no one doing anything.
    func selfTest(_ keys: WatchKeys) async -> [String: Any] {
        var result: [String: Any] = ["at": Int(Date().timeIntervalSince1970)]
        do {
            // A login sealed to this Watch's opening key, opened by its chip.
            var secret = LoginSecret()
            secret.loginID = "self-test"
            secret.password = "example"
            let openerID = try keys.keyID()
            let opening = try P256.KeyAgreement.PublicKey(x963Representation: keys.openingPublicKey())
            let sealed = try Sealing.seal(secret, to: opening, openerID: openerID)
            result["keyOpens"] = try keys.open(sealed).password == "example"
        } catch { result["keyOpens"] = false; result["keyError"] = "\(error)" }
        var error: NSError?
        result["passcodeSet"] = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        let context = LAContext()
        context.interactionNotAllowed = true
        result["onWristAndUnlocked"] = (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithWristDetection, localizedReason: "Check")) ?? false
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        result["notificationsAllowed"] = settings.authorizationStatus == .authorized
        result["timeSensitiveAllowed"] = settings.timeSensitiveSetting == .enabled
        result["pushAddress"] = pushToken != nil
        if let lastProblem { result["problem"] = lastProblem }
        return result
    }

    // MARK: Receiving

    private func receive(_ payload: [String: Any]) {
        let store = WatchStore()
        let saved = store.read()
        let next = saved.merging(members: payload["members"] as? Data, catalogue: payload["catalogue"] as? Data,
                                 answerURL: payload["relayAnswerURL"] as? String, settings: payload["settings"] as? Data)
        if next != saved { store.write(next) }
        Task { await refreshSetup() }
    }

    /// Where setup stands, worked out again from what the Watch can read about itself.
    func refreshSetup() async {
        let saved = WatchStore().read()
        var error: NSError?
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let setup = WatchSetup(passcode: LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error),
                               // Any Members at all means the iPhone has joined; until it lists this Apple Watch, the request waits there.
                               phoneJoined: saved.signedMembers != nil,
                               listed: saved.lists((try? WatchKeys().keyID()) ?? ""),
                               notifications: status == .notDetermined ? .notAsked : status == .denied ? .denied : .allowed,
                               pushAddress: pushToken != nil)
        let inUse = WatchStore().read().currentInUse
        await MainActor.run { WatchModel.shared.setup = setup; WatchModel.shared.inUse = inUse }
    }

    /// Stop on Apple Watch: the iPhone ends the approval at the relay. True once it has.
    func stop(_ id: String) async -> Bool {
        let session = WCSession.default
        activate()
        for _ in 0..<30 where session.activationState != .activated || !session.isReachable { try? await Task.sleep(for: .milliseconds(100)) }
        guard session.isReachable else { return false }
        let stopped: Bool = await withCheckedContinuation { done in
            session.sendMessage(["stop": id], replyHandler: { done.resume(returning: $0["stopped"] as? Bool ?? false) },
                                errorHandler: { _ in done.resume(returning: false) })
        }
        if stopped {
            let store = WatchStore()
            store.write(store.read().removingInUse(id))
            await refreshSetup()
        }
        return stopped
    }

    /// Asks the iPhone for the current list of devices, for a request this Watch
    /// cannot read: the iPhone answers at once if it can be woken, and also sends
    /// it the usual way. True if a newer list arrived.
    func askForMembers() async -> Bool {
        let session = WCSession.default
        // Opening a notification may have just started the app: its session activates a moment later.
        activate()
        for _ in 0..<30 where session.activationState != .activated { try? await Task.sleep(for: .milliseconds(100)) }
        guard session.activationState == .activated else { return false }
        let before = WatchStore().read()
        session.transferUserInfo(["askMembers": true])
        for _ in 0..<30 where !session.isReachable { try? await Task.sleep(for: .milliseconds(100)) }
        guard session.isReachable else { return false }
        // The reply crosses as a property list: its members bytes and the answer address.
        let reply: Data? = await withCheckedContinuation { done in
            session.sendMessage(["askMembers": true], replyHandler: {
                done.resume(returning: try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0))
            }, errorHandler: { _ in done.resume(returning: nil) })
        }
        guard let reply, let payload = try? PropertyListSerialization.propertyList(from: reply, format: nil) as? [String: Any] else { return false }
        receive(payload)
        return WatchStore().read() != before
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if state == .activated {
            if !session.receivedApplicationContext.isEmpty { receive(session.receivedApplicationContext) }
            Task { await sendHandOver() }
        }
        drainIdle()
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
        drainIdle()
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receive(userInfo)
        drainIdle()
    }
}
