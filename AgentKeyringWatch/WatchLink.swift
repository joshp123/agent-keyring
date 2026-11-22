// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The one hand-over between the Watch and its iPhone, over Watch
// Connectivity. The Watch sends what its self-test found, its push address,
// and its keys once he has tapped Add; the iPhone sends the signed Members and
// Catalogue, its settings, and the end of the Face ID confirmation it holds
// while it waits for this Watch to ask. Each side sends with both
// transferUserInfo and updateApplicationContext, so it arrives whichever app
// runs first.

import AgentKeyringProtocol
import AgentKeyringSealing
import AgentKeyringWatchCore
import CryptoKit
import Foundation
import LocalAuthentication
import UserNotifications
import WatchConnectivity

/// The Watch app's lines, or its notification extension's, in the ring they share.
let watchLog = DeviceLog(device: "watch")

final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchLink()

    private let lock = NSLock()
    private var _pushToken: Data?
    private var _lastProblem: String?
    private var _refreshGeneration: UInt64 = 0
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

    /// Builds the Watch's device identity and optional push registration, independent of self-test or logs.
    private func pairingPayload(includeDevice: Bool, offerID: String? = nil) throws -> [String: Any] {
        let keys = WatchKeys()
        var payload: [String: Any] = [:]
        if includeDevice {
            payload["watchDevice"] = try keys.device().serializedData()
            if let offerID { payload["addOfferID"] = offerID }
        }
        if let token = pushToken {
            var push = Agentkeyring_V2_PushRegistration()
            push.deviceKeyID = try keys.keyID()
            push.apnsToken = token
            push.apnsTopic = Bundle.main.bundleIdentifier ?? ""
            push.apnsProduction = PushEnvironment.isProduction
            push.noticePublicKey = try keys.noticePublicKey()
            payload["watchPush"] = try push.serializedData()
        }
        return payload
    }

    /// The Watch's keys, push address and self-test, for the iPhone to add it.
    func sendHandOver() async {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let keys = WatchKeys()
        // The Watch's recent log lines ride along; keep under WatchConnectivity's 65 KB context limit.
        watchLog.collect()
        var payload: [String: Any] = ["watchSelfTest": await selfTest(keys), "log": watchLog.lines(last: 60)]
        do {
            let saved = WatchStore().read()
            let keyID = try keys.keyID()
            let tappedOfferID = saved.addTappedOfferID
            let includeDevice = tappedOfferID != nil && tappedOfferID == saved.effectiveAddOfferID && !saved.lists(keyID)
            let pairing = try pairingPayload(includeDevice: includeDevice, offerID: includeDevice ? tappedOfferID : nil)
            for (k, v) in pairing { payload[k] = v }
        } catch {
            lastProblem = "The Watch could not make its keys: \(error)"
        }
        do { try session.updateApplicationContext(payload) } catch { log.error("context: \(error.localizedDescription, privacy: .public)") }
    }

    /// A problem the person sees as one plain line; the detail goes to the iPhone, which reports it.
    func report(problem: String) {
        watchLog.note("app", "problem", ["msg": problem])
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
            let sealed = try Sealing.seal(secret, version: 0, to: opening, openerID: openerID,
                                          signer: Sealing.Signer(keyID: Sealing.keyID(keys.replyPublicKey()), sign: keys.signReply))
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
        result["practiceAnswered"] = WatchStore().read().practiceAnswered == true
        if let lastProblem { result["problem"] = lastProblem }
        return result
    }

    // MARK: Receiving

    /// `current`: the iPhone's latest context, whose Add offer stands; queued user info may be older.
    @discardableResult
    private func receive(_ payload: [String: Any], current: Bool) -> Date? {
        let store = WatchStore()
        let keyID = (try? WatchKeys().keyID()) ?? ""
        var resolvedAddUntil: Date?
        var wasRemoved = false
        store.update { saved in
            let wasListed = !keyID.isEmpty && saved.lists(keyID)
            let addUntil = current ? (payload["addUntil"] as? Double).map(Date.init(timeIntervalSince1970:)) : saved.addUntil
            let addOfferID = current ? (payload["addOfferID"] as? String) : saved.addOfferID
            let copiesPending = current ? (payload["copiesPending"] as? Bool) : saved.copiesPending
            let copyingToWatch = current ? (payload["copyingToWatch"] as? Bool) : saved.copyingToWatch
            resolvedAddUntil = addUntil
            var next = saved.merging(members: payload["members"] as? Data, catalogue: payload["catalogue"] as? Data,
                                     settings: payload["settings"] as? Data, addUntil: addUntil, addOfferID: addOfferID,
                                     copiesPending: copiesPending, copyingToWatch: copyingToWatch)
            let nowListed = !keyID.isEmpty && next.lists(keyID)
            if nowListed {
                if next.copiesPending != true && next.copyingToWatch != true {
                    next.addTappedOfferID = nil
                } else if next.copyingToWatch == true, let activeOffer = next.addOfferID, !activeOffer.isEmpty {
                    // If Face ID was renewed for a listed Watch with pending copies, track the active offer ID.
                    next.addTappedOfferID = activeOffer
                }
            } else if wasListed {
                // Removed from Members: wipe Watch-local setup/practice flags so a future re-add starts fresh.
                wasRemoved = true
                next.addTappedOfferID = nil
                next.copiesPending = nil
                next.copyingToWatch = nil
                next.practiceAnswered = nil
                next.practiceOfferDone = nil
                next.practiceAsked = nil
                next.inUse = nil
            } else if next.copyingToWatch != true {
                let expired = addUntil == nil || (addUntil ?? .distantPast) <= .now
                if expired || next.effectiveAddOfferID != next.addTappedOfferID {
                    next.addTappedOfferID = nil
                }
            }
            saved = next
        }
        if wasRemoved {
            store.clearInUse()
            lastProblem = nil
        }
        // The iPhone's wait ends at its deadline: Add then goes from the screen by itself.
        if let addUntil = resolvedAddUntil, addUntil > .now {
            Task { try? await Task.sleep(for: .seconds(addUntil.timeIntervalSinceNow + 1)); await self.refreshSetup() }
        }
        return resolvedAddUntil
    }

    /// Add on this Watch: sends its keys immediately via live message when the iPhone app is open,
    /// falling back cleanly with an honest error instead of hanging indefinitely.
    func add() async -> Bool {
        let session = WCSession.default
        activate()
        for _ in 0..<20 where session.activationState != .activated {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard session.activationState == .activated else {
            watchLog.note("setup", "add failed", ["reason": "session not activated"])
            return false
        }
        guard let offerID = WatchStore().read().effectiveAddOfferID, !offerID.isEmpty else {
            watchLog.note("setup", "add failed", ["reason": "no active offer"])
            await refreshSetup()
            return false
        }
        let pairing: [String: Any]
        do {
            pairing = try pairingPayload(includeDevice: true, offerID: offerID)
        } catch {
            lastProblem = "The Watch could not make its keys: \(error)"
            watchLog.note("setup", "add failed", ["reason": "\(error)"])
            return false
        }
        WatchStore().update { $0.addTappedOfferID = offerID }
        watchLog.note("setup", "add tapped", [:])
        await refreshSetup()

        // Always publish a lean context without waiting on selfTest or 200 log lines.
        do { try session.updateApplicationContext(pairing) } catch { log.error("add context: \(error.localizedDescription, privacy: .public)") }

        for _ in 0..<20 where !session.isReachable {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if session.isReachable {
            var message = pairing
            message["addWatch"] = true
            let replyData: Data? = await withCheckedContinuation { done in
                session.sendMessage(message, replyHandler: {
                    done.resume(returning: try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0))
                }, errorHandler: { error in
                    watchLog.note("setup", "add message failed", ["error": "\(error)"])
                    done.resume(returning: nil)
                })
            }
            if let replyData, let reply = try? PropertyListSerialization.propertyList(from: replyData, format: nil) as? [String: Any] {
                receive(reply, current: true)
                let accepted = reply["accepted"] as? Bool ?? true
                if !accepted {
                    WatchStore().update { if $0.addTappedOfferID == offerID { $0.addTappedOfferID = nil } }
                    await refreshSetup()
                    return false
                }
                await refreshSetup()
                Task { await self.sendHandOver() }
                return true
            }
        }
        // iPhone app was not reachable over Bluetooth: clear this offer's tap instead of trapping the Watch forever.
        WatchStore().update { if $0.addTappedOfferID == offerID { $0.addTappedOfferID = nil } }
        await refreshSetup()
        return false
    }

    /// Cancel while waiting on "Preparing your Watch…": clears local state and tells the iPhone
    /// to abort the matching offer so a previously sent Add cannot still enrol on the iPhone.
    func cancelAdd() async {
        let store = WatchStore()
        let before = store.read()
        // Prefer the current offer ID reported by the iPhone (covers renewed Face ID retries).
        let offerID = before.addOfferID ?? before.addTappedOfferID
        store.update { $0.addTappedOfferID = nil }
        watchLog.note("setup", "add cancelled", [:])
        await refreshSetup()
        let session = WCSession.default
        guard session.activationState == .activated, let offerID, !offerID.isEmpty else { return }
        let cancelPayload: [String: Any] = ["cancelAddWatch": true, "addOfferID": offerID]
        if session.isReachable {
            let replyData: Data? = await withCheckedContinuation { done in
                session.sendMessage(cancelPayload, replyHandler: {
                    done.resume(returning: try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0))
                }, errorHandler: { _ in done.resume(returning: nil) })
            }
            if let replyData, let reply = try? PropertyListSerialization.propertyList(from: replyData, format: nil) as? [String: Any] {
                receive(reply, current: true)
                await refreshSetup()
                if let cancelled = reply["cancelled"] as? Bool {
                    if !cancelled {
                        watchLog.note("setup", "cancel refused by iPhone", ["reason": "upload already in flight or offer ended"])
                    }
                    Task { await self.sendHandOver() }
                    return
                }
                watchLog.note("setup", "cancel not acknowledged by iPhone", ["reason": "older iPhone build"])
            }
        }
        session.transferUserInfo(cancelPayload)
        Task { await self.sendHandOver() }
    }

    /// Try Practice: only an iPhone or the Mac can ask the Mac for a practice request, so the iPhone asks.
    func askForPractice() async -> Bool {
        let session = WCSession.default
        activate()
        for _ in 0..<30 where session.activationState != .activated || !session.isReachable { try? await Task.sleep(for: .milliseconds(100)) }
        guard session.isReachable else { return false }
        let asked: Bool = await withCheckedContinuation { done in
            session.sendMessage(["practice": true], replyHandler: { done.resume(returning: $0["asked"] as? Bool ?? false) },
                                errorHandler: { _ in done.resume(returning: false) })
        }
        watchLog.note("practice", asked ? "asked" : "not asked", [:])
        if asked {
            WatchStore().update { $0.practiceAsked = .now }
            Task { try? await Task.sleep(for: .seconds(WatchSetup.practiceWait + 1)); await self.refreshSetup() }
        }
        await refreshSetup()
        return asked
    }

    /// Cancel while waiting for the practice request: the offer comes back.
    func cancelPractice() async {
        WatchStore().update { $0.practiceAsked = nil }
        await refreshSetup()
    }

    /// Done on the practice offer.
    func practiceOfferDone() async {
        WatchStore().update { $0.practiceOfferDone = true }
        await refreshSetup()
    }

    /// Where setup stands, worked out again from what the Watch can read about itself.
    /// Uses a monotonic generation so an older async notificationSettings() lookup never overwrites newer state.
    func refreshSetup() async {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "SampleSetup") != nil { return }
        #endif
        let generation: UInt64 = lock.withLock {
            _refreshGeneration &+= 1
            return _refreshGeneration
        }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let saved = WatchStore().read()
        var error: NSError?
        let setup = WatchSetup(passcode: LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error),
                               // Any Members at all means the iPhone has joined a Mac.
                               phoneJoined: saved.signedMembers != nil,
                               listed: saved.lists((try? WatchKeys().keyID()) ?? ""),
                               addOffered: saved.addUntil.map { $0 > .now } ?? false,
                               addTapped: saved.isAddTappedForCurrentOffer,
                               copiesPending: saved.copiesPending == true,
                               copyingToWatch: saved.copyingToWatch == true,
                               notifications: status == .notDetermined ? .notAsked : status == .denied ? .denied : .allowed,
                               pushAddress: pushToken != nil,
                               practiceAsked: saved.practiceAnswered == true ? nil : saved.practiceAsked,
                               practiceOfferDone: saved.practiceOfferDone == true)
        let inUse = WatchStore().readInUse()
        await MainActor.run {
            let isLatest = self.lock.withLock { self._refreshGeneration == generation }
            guard isLatest else { return }
            WatchModel.shared.setup = setup
            WatchModel.shared.inUse = inUse
        }
    }

    /// Stop on Apple Watch: the iPhone ends the approval at the asking computer's door. True once it has.
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
            WatchStore().removeInUse(id)
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
        receive(payload, current: true)
        await refreshSetup()
        return WatchStore().read() != before
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else {
            drainIdle()
            return
        }
        let context = session.receivedApplicationContext
        if !context.isEmpty { receive(context, current: true) }
        Task {
            await self.refreshSetup()
            await self.sendHandOver()
            self.drainIdle()
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext, current: true)
        Task {
            await self.refreshSetup()
            self.drainIdle()
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receive(userInfo, current: false)
        Task {
            await self.refreshSetup()
            self.drainIdle()
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message, current: true)
        Task { await self.refreshSetup() }
    }
}
