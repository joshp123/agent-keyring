// Written by AI on 2026.11.18 by model Claude Opus 5.5; edited on 2026.11.27 by model claude opus 5.5.
//
// Apple Watch: its pairing and self-test, and adding it with Face ID held until it asks.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication

@MainActor
extension PhoneKeyringEngine {
    // MARK: Apple Watch

    /// Try Practice on Apple Watch: this iPhone makes the Watch's practice request. False if it cannot be pushed.
    public func practiceForWatch() async -> Bool {
        guard let watch = members?.devices.first(where: { $0.kind == .watch }) else { return false }
        do { _ = try await originatePractice(for: watch.keyID, id: PhoneFirstRun.newPracticeID()); return true }
        catch { KeyringDiagnosticLog.iPhone.noteDeviceEvent("practice", "not made", ["device": "watch", "error": "\(error)"]); return false }
    }

    /// What WatchConnectivity says: an Apple Watch is paired, and Agent Keyring's Watch app is on it.
    public func watchPairing(paired: Bool, installed: Bool) {
        guard (paired, installed) != (watchPaired, watchInstalled) else { return }
        watchPaired = paired; watchInstalled = installed
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("watch", "pairing", ["paired": "\(paired)", "installed": "\(installed)"])
        applyAddWatch(.checked(paired: paired, installed: installed))
        publish()
    }

    /// The Apple Watch's facts, from WatchConnectivity, its self-test, and the list of devices.
    func watchFacts(_ members: Members) -> PhoneWatchFacts {
        let test = state.watchSelfTest.flatMap { try? Agentkeyring_V2_WatchSelfTest(serializedBytes: $0) }
        var facts = PhoneWatchFacts()
        facts.paired = watchPaired
        facts.installed = watchInstalled
        let listedWatch = members.devices.first { $0.kind == .watch }
        facts.added = listedWatch != nil
        facts.copiesPending = listedWatch != nil && state.watchCopiesPending == listedWatch?.keyID
        facts.opened = facts.added || state.watchDevice != nil || state.watchSelfTest != nil
        facts.notificationsAllowed = test?.notificationsAllowed == true
        facts.pushAddress = test?.pushAddress == true
        facts.practiceAnswered = test?.practiceAnswered == true
        return facts
    }

    /// The Watch's own self-test, as its app sent it.
    public func watchTested(_ test: Agentkeyring_V2_WatchSelfTest) {
        var next = state
        next.watchSelfTest = try? test.serializedData()
        save(next)
        if !test.passcodeSet { applyAddWatch(.watchHasNoPasscode) }
    }

    struct WatchHold {
        let context: LAContext
        let until: Date
        let offerID: String
        let timer: Task<Void, Never>

        func invalidate() {
            timer.cancel()
            context.invalidate()
        }
    }

    enum WatchEnrollment {
        case none
        case idle(PhoneAddWatch)
        case authorizing(PhoneAddWatch, committedWatchKeyID: String?)
        case holding(flow: PhoneAddWatch, hold: WatchHold)
        case encrypting(flow: PhoneAddWatch, hold: WatchHold, task: Task<Void, Never>, generation: UInt64, watchKeyID: String?)
        case enrolledDeliveryPending(flow: PhoneAddWatch?, watchKeyID: String, hold: WatchHold?)
        case uploading(flow: PhoneAddWatch?, offerID: String, watchKeyID: String, hold: WatchHold?, task: Task<Void, Never>, generation: UInt64)

        var flow: PhoneAddWatch? {
            switch self {
            case .none: nil
            case let .idle(flow), let .authorizing(flow, _), let .holding(flow, _), let .encrypting(flow, _, _, _, _): flow
            case let .enrolledDeliveryPending(flow, _, _), let .uploading(flow, _, _, _, _, _): flow
            }
        }

        var offerID: String? {
            switch self {
            case let .holding(_, hold), let .encrypting(_, hold, _, _, _): hold.offerID
            case let .enrolledDeliveryPending(_, _, hold): hold?.offerID
            case let .uploading(_, offerID, _, _, _, _): offerID
            case .none, .idle, .authorizing: nil
            }
        }

        var addUntil: Date? {
            switch self {
            case let .holding(flow, hold) where flow.watchMayAsk: hold.until
            case let .enrolledDeliveryPending(flow?, _, hold?) where flow.watchMayAsk: hold.until
            case .none, .idle, .authorizing, .holding, .encrypting, .enrolledDeliveryPending, .uploading: nil
            }
        }

        var hold: WatchHold? {
            switch self {
            case let .holding(_, hold), let .encrypting(_, hold, _, _, _): hold
            case let .enrolledDeliveryPending(_, _, hold), let .uploading(_, _, _, hold, _, _): hold
            case .none, .idle, .authorizing: nil
            }
        }

        var committedWatchKeyID: String? {
            switch self {
            case let .authorizing(_, watchKeyID): watchKeyID
            case let .encrypting(_, _, _, _, watchKeyID): watchKeyID
            case let .enrolledDeliveryPending(_, watchKeyID, _), let .uploading(_, _, watchKeyID, _, _, _): watchKeyID
            case .none, .idle, .holding: nil
            }
        }

        var isEnrolledDeliveryPending: Bool {
            if case .enrolledDeliveryPending = self { true } else { false }
        }

        var isCommitted: Bool {
            committedWatchKeyID != nil
        }

        var isCopying: Bool {
            switch self {
            case .encrypting, .uploading: true
            case .none, .idle, .authorizing, .holding, .enrolledDeliveryPending: false
            }
        }

        var isUploading: Bool {
            if case .uploading = self { true } else { false }
        }

        var encryptionTask: Task<Void, Never>? {
            switch self {
            case let .encrypting(_, _, task, _, _), let .uploading(_, _, _, _, task, _): task
            case .none, .idle, .authorizing, .holding, .enrolledDeliveryPending: nil
            }
        }

        var generation: UInt64? {
            switch self {
            case let .encrypting(_, _, _, gen, _), let .uploading(_, _, _, _, _, gen): gen
            case .none, .idle, .authorizing, .holding, .enrolledDeliveryPending: nil
            }
        }

        mutating func withFlow(_ next: PhoneAddWatch?) {
            switch self {
            case .none:
                if let next { self = .idle(next) }
            case .idle:
                if let next { self = .idle(next) } else { self = .none }
            case let .authorizing(_, watchKeyID):
                if let next {
                    self = .authorizing(next, committedWatchKeyID: watchKeyID)
                } else if let watchKeyID {
                    self = .enrolledDeliveryPending(flow: nil, watchKeyID: watchKeyID, hold: nil)
                } else {
                    self = .none
                }
            case let .holding(_, hold):
                if let next { self = .holding(flow: next, hold: hold) } else { self = .none }
            case let .encrypting(_, hold, task, gen, watchKeyID):
                if let next {
                    self = .encrypting(flow: next, hold: hold, task: task, generation: gen, watchKeyID: watchKeyID)
                } else if let watchKeyID {
                    self = .enrolledDeliveryPending(flow: nil, watchKeyID: watchKeyID, hold: hold)
                } else {
                    self = .none
                }
            case let .enrolledDeliveryPending(_, watchKeyID, hold):
                self = .enrolledDeliveryPending(flow: next, watchKeyID: watchKeyID, hold: hold)
            case let .uploading(_, offerID, watchKeyID, hold, task, gen):
                self = .uploading(flow: next, offerID: offerID, watchKeyID: watchKeyID, hold: hold, task: task, generation: gen)
            }
        }
    }

    var addWatchFlow: PhoneAddWatch? { watchEnrollment.flow }

    /// Unique identifier for the currently active Face ID Add Watch offer, kept alive through
    /// encryption and retries until completion or cancellation so the Watch can always cancel it.
    public var activeWatchOfferID: String? { watchEnrollment.offerID }

    /// The end of the held Face ID confirmation while the iPhone waits for Apple Watch to ask.
    public var watchAddUntil: Date? { watchEnrollment.addUntil }

    /// The latest generation acknowledged by Apple Watch.
    public var watchCopiesHeld: UInt64? { state.watchCopiesHeld }

    /// True while this iPhone is actively waiting for or processing an Apple Watch Add tap
    /// (or the Watch is already listed in Members with copies complete).
    var isAcceptingWatchAdd: Bool {
        if members?.devices.contains(where: { $0.kind == .watch }) == true, !watchCopiesPending { return true }
        switch addWatchFlow {
        case .waitingForWatch?, .encrypting?, .added?: return true
        case nil, .notPaired?, .watchAppMissing?, .faceIDFirst?, .faceIDExpired?, .watchNeedsPasscode?, .copiesFailed?, .closed?:
            return false
        }
    }

    /// True when the Watch is listed in Members but its encrypted copies have not yet been acknowledged.
    public var watchCopiesPending: Bool {
        guard let pending = state.watchCopiesPending else { return false }
        return members?.devices.contains(where: { $0.kind == .watch && $0.keyID == pending }) == true
    }

    /// True while this iPhone is actively encrypting/uploading copies for Apple Watch.
    public var isCopyingToWatch: Bool {
        if watchEnrollment.isCopying { return true }
        if case .encrypting = addWatchFlow { return true }
        return false
    }


    func applyAddWatch(_ event: PhoneAddWatchEvent) {
        if event == .cancel, (watchEnrollment.isCommitted || watchCopiesPending) {
            return
        }
        guard let flow = watchEnrollment.flow else { return }
        let next = flow.on(event)
        guard next != flow else { return }
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("addwatch", "moved", ["from": "\(flow)", "to": "\(next)", "by": "\(event)"])
        let notifyEnded = !next.watchMayAsk && (flow.watchMayAsk || next == .closed)
        if next == .faceIDExpired || next == .closed || next == .added {
            if case let .uploading(_, offerID, watchKeyID, hold, task, gen) = watchEnrollment, next != .added {
                // Once the final copy upload is already in flight, let it finish committing
                // even if the sheet closes or Face ID expires.
                if next == .faceIDExpired { hold?.invalidate() }
                watchEnrollment = .uploading(
                    flow: next == .closed ? nil : next,
                    offerID: offerID,
                    watchKeyID: watchKeyID,
                    hold: next == .faceIDExpired ? nil : hold,
                    task: task,
                    generation: gen
                )
            } else if case let .enrolledDeliveryPending(_, watchKeyID, hold) = watchEnrollment, next != .added {
                hold?.invalidate()
                watchEnrollment = .enrolledDeliveryPending(
                    flow: next == .closed ? nil : next,
                    watchKeyID: watchKeyID,
                    hold: nil
                )
            } else if case let .encrypting(_, _, _, _, watchKeyID?) = watchEnrollment, next != .added {
                // Membership is already published; keep encryption running while updating UI state.
                _ = watchKeyID
                watchEnrollment.withFlow(next == .closed ? nil : next)
            } else {
                watchEnrollment.hold?.invalidate()
                if next != .added {
                    addingWatchGeneration &+= 1
                    watchEnrollment.encryptionTask?.cancel()
                    if state.watchDevice != nil {
                        var cleared = state
                        cleared.watchDevice = nil
                        save(cleared)
                    }
                }
                watchEnrollment = (next == .closed ? .none : .idle(next))
            }
        } else {
            watchEnrollment.withFlow(next)
        }
        if notifyEnded { onWatchMayAsk?() }
        if case .waitingForWatch = next { onWatchMayAsk?() }
        if case .encrypting = next, case .encrypting = flow {} else if case .encrypting = next { onListsChanged?() }
        if case .copiesFailed = next { onListsChanged?() }
        if next == .added { onListsChanged?() }
        if next == .closed, firstRun == .addWatch { apply(.done) }
        publish()
        // Resume copying immediately only when Watch is already listed and still lacks acknowledged copies.
        if case .waitingForWatch = next, watchLacksCopies { addWatchNow() }
    }

    func openAddWatch() {
        switch watchEnrollment {
        case .none:
            if watchCopiesPending, let watchID = listedWatch?.keyID {
                watchEnrollment = .enrolledDeliveryPending(flow: .faceIDExpired, watchKeyID: watchID, hold: nil)
            } else {
                watchEnrollment = .idle(.initialFlow(paired: watchPaired, installed: watchInstalled))
            }
        case let .enrolledDeliveryPending(nil, watchKeyID, hold):
            if let hold, hold.until > Date() {
                watchEnrollment = .enrolledDeliveryPending(
                    flow: .copiesFailed(reason: PhoneCopy.watchNotReached),
                    watchKeyID: watchKeyID,
                    hold: hold
                )
            } else {
                hold?.invalidate()
                watchEnrollment = .enrolledDeliveryPending(flow: .faceIDExpired, watchKeyID: watchKeyID, hold: nil)
            }
        case let .uploading(nil, offerID, watchKeyID, hold, task, gen):
            let total = catalogue?.logins.filter(\.holdsSecret).count ?? 0
            watchEnrollment = .uploading(
                flow: .encrypting(done: total, total: total),
                offerID: offerID,
                watchKeyID: watchKeyID,
                hold: hold,
                task: task,
                generation: gen
            )
        case .idle, .authorizing, .holding, .encrypting, .enrolledDeliveryPending, .uploading:
            break
        }
        publish()
    }

    public func handleAddWatchTap(_ tap: PhoneAddWatchTap) async {
        switch tap {
        case .open:
            if addWatchFlow == nil { openAddWatch() }
        case .checkAgain: applyAddWatch(.checked(paired: watchPaired, installed: watchInstalled))
        case .continueWithFaceID: await confirmForWatch()
        case .tryAgain:
            if case .copiesFailed = addWatchFlow {
                if let hold = watchEnrollment.hold, hold.until > Date() {
                    addWatchNow()
                } else {
                    applyAddWatch(.confirmationLapsed)
                }
            } else {
                applyAddWatch(.tryAgain(now: Date()))
            }
        case .cancel: applyAddWatch(.cancel)
        case .done: applyAddWatch(.done)
        }
    }

    /// Face ID first, with its reason; the confirmation is then held until its shown end, and nothing is
    /// decrypted until Apple Watch asks.
    func confirmForWatch() async {
        let initialFlow: PhoneAddWatch
        let committedWatchKeyID: String?
        switch watchEnrollment {
        case let .idle(flow):
            initialFlow = flow
            committedWatchKeyID = nil
        case let .enrolledDeliveryPending(flow?, watchKeyID, _):
            initialFlow = flow
            committedWatchKeyID = watchKeyID
        case .none, .authorizing, .holding, .encrypting, .enrolledDeliveryPending, .uploading:
            return
        }
        guard initialFlow == .faceIDFirst || initialFlow == .faceIDExpired else { return }
        watchEnrollment = .authorizing(initialFlow, committedWatchKeyID: committedWatchKeyID)
        let context = LAContext()
        do { try await keys.authorize(context, reason: PhoneCopy.faceIDAddWatch) }
        catch {
            context.invalidate()
            if case let .authorizing(current, watchKeyID) = watchEnrollment {
                if let watchKeyID {
                    watchEnrollment = .enrolledDeliveryPending(flow: current, watchKeyID: watchKeyID, hold: nil)
                } else {
                    watchEnrollment = .idle(current)
                }
            }
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("addwatch", "face id not given", ["error": "\(error)"])
            return
        }
        guard case let .authorizing(current, watchKeyID) = watchEnrollment,
              current == .faceIDFirst || current == .faceIDExpired else {
            context.invalidate()
            return
        }
        let until = Date().addingTimeInterval(PhoneAddWatch.hold)
        let offerID = UUID().uuidString
        let holdTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(PhoneAddWatch.hold)) } catch { return }
            self?.applyAddWatch(.confirmationLapsed)
        }
        let hold = WatchHold(context: context, until: until, offerID: offerID, timer: holdTimer)
        if let watchKeyID {
            watchEnrollment = .enrolledDeliveryPending(flow: current, watchKeyID: watchKeyID, hold: hold)
        } else {
            watchEnrollment = .holding(flow: current, hold: hold)
        }
        applyAddWatch(.confirmed(until: until))
    }

    /// Apple Watch is listed but has not yet acknowledged its encrypted copies.
    var watchLacksCopies: Bool {
        if case .copiesFailed = addWatchFlow { return true }
        return watchCopiesPending
    }

    /// Apple Watch tapped Cancel while preparing for `offerID`: stop the in-flight Add if it matches this offer.
    /// Returns true only when an active matching offer was cancelled (refused once membership is published or copy upload has started).
    @discardableResult
    public func cancelWatchOffer(offerID: String?) -> Bool {
        guard !watchEnrollment.isCommitted, !watchEnrollment.isUploading, !watchCopiesPending,
              let active = activeWatchOfferID, let offerID, offerID == active else { return false }
        switch addWatchFlow {
        case .waitingForWatch?, .watchNeedsPasscode?, .encrypting?, .copiesFailed?:
            applyAddWatch(.cancel)
            return true
        case nil, .notPaired?, .watchAppMissing?, .faceIDFirst?, .faceIDExpired?, .added?, .closed?:
            return false
        }
    }

    /// The Watch's app sent its keys after Add, its push address, or both. Keys are ONLY accepted
    /// while this iPhone is actively waiting on the matching Face ID offer; late Watch Add payloads
    /// after Cancel or expiry are discarded so a cancelled Watch can never enrol on a later Face ID.
    @discardableResult
    public func watchOffered(device: Data?, push: Data?, offerID: String? = nil) -> Bool {
        let parsed = device.flatMap { try? Agentkeyring_V2_Device(serializedBytes: $0) }
        let pushRegistration = push.flatMap { try? Agentkeyring_V2_PushRegistration(serializedBytes: $0) }
        let listed = members?.devices.first { $0.kind == .watch && $0.keyID == (parsed?.keyID ?? pushRegistration?.deviceKeyID) }
        if let push {
            var next = state
            next.watchPush = push
            save(next)
        }
        if listed != nil {
            if let pushRegistration, let push { Task { await registerWatchPush(pushRegistration, raw: push) } }
            if !watchCopiesPending { return true }
            if let active = activeWatchOfferID, let offerID, offerID == active, isCopyingToWatch { return true }
            return false
        }
        guard let parsed, parsed.kind == .watch, let device else { return false }
        // A duplicate Add arriving via live message after applicationContext already started
        // encryption for this exact offer should report progress, not failure.
        if let active = activeWatchOfferID, let offerID, offerID == active {
            switch addWatchFlow {
            case .encrypting?, .added?: return true
            case nil, .notPaired?, .watchAppMissing?, .faceIDFirst?, .waitingForWatch?, .faceIDExpired?, .watchNeedsPasscode?, .copiesFailed?, .closed?:
                break
            }
        }
        guard case .waitingForWatch = addWatchFlow else {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("addwatch", "discarded late watch offer", ["reason": "not waiting"])
            return false
        }
        if let active = activeWatchOfferID, let offerID, offerID != active {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("addwatch", "discarded stale watch offer", ["reason": "offer mismatch"])
            return false
        }
        var next = state
        next.watchDevice = device
        save(next)
        addWatchNow()
        return true
    }

    func registerWatchPush(_ registration: Agentkeyring_V2_PushRegistration, raw: Data) async {
        do {
            try await post(registration)
            var done = state
            if done.watchPush == raw {
                done.watchPush = nil
                save(done)
            }
        } catch { KeyringDiagnosticLog.iPhone.noteDeviceEvent("watch", "push address not registered", ["error": "\(error)"]) }
    }
}
