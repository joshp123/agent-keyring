// Written by AI on 2026.11.21 by model Claude Opus 5.5.
//
// Apple Watch's own pages, from the shared page parts: one per state of
// WatchSetup, and "In use" with Stop. Every word is in WatchCopy.

import AgentKeyringDesign
import AgentKeyringWatchCore
import SwiftUI
import UserNotifications

/// Every word Apple Watch shows, from master-copy-audit-21-nov.md. Apple Watch keeps no passwords, so no
/// line says it receives or syncs them.
enum WatchCopy {
    static func page(_ setup: WatchSetup) -> (title: String, detail: String?) {
        switch setup {
        case .noPasscode: ("Passcode needed", "Turn on a passcode for this Watch in Apple’s Watch app.")
        case .setUpIPhone: ("Set up iPhone first", "Set up Agent Keyring on your iPhone, then tap Add Apple Watch in Devices.")
        case .startOnIPhone: ("Start on your iPhone", "Open Agent Keyring on your iPhone, go to Devices, and tap Add Apple Watch.")
        case .readyToAdd: ("Add this Watch?", "Approve password requests on your wrist.")
        case .preparing: ("Preparing your Watch…", nil)
        case .notifications: ("Turn on notifications", "Allow notifications so requests reach your wrist.")
        case .notificationsOff: ("Notifications are off", "Turn them on in Settings on your Watch.")
        case .settingUpNotifications: ("Setting up notifications", "Apple is connecting this Watch for notifications. This usually takes a few seconds.")
        case .addedOfferPractice: ("Apple Watch added", "Ready for password requests.")
        case .practiceWaiting: ("Waiting for practice request…", nil)
        case .ready: ("Ready", "Requests appear here as notifications. Tap Approve or Deny.")
        }
    }
    static let continueButton = "Continue"
    static let add = "Add"
    static let tryPractice = "Try Practice"
    static let done = "Done"
    static let cancel = "Cancel"
    static let checkAgain = "Check Again"
    /// Not in the ledger: when Try Practice cannot reach the iPhone, or the iPhone cannot reach the Mac.
    static let practiceNotAsked = "Couldn’t ask for one. Your iPhone and Mac need to be nearby and awake."
    // The request card.
    static let deny = "Deny"
    static let approve = "Approve"
    static let denyAndExplain = "Deny and Explain"
    static let whatInstead = "What should it do instead?"
    static let unreadable = "Open Agent Keyring on your iPhone to see this request."
    static let practiceLead = "Practice request"
    static func answered(approve: Bool, _ result: WatchDelegate.AnswerResult) -> String {
        switch (approve, result) {
        case (_, .alreadyAnswered): "Already answered"
        case (true, .sent): "Approved"
        case (false, .sent): "Denied"
        case (true, .failed): "Not approved. Try on your iPhone."
        case (false, .failed): "Not sent. Try on your iPhone."
        }
    }
    static let inUse = "In use"
    static let stop = "Stop"
    /// Not in the ledger: when Stop can't reach the iPhone.
    static let stopFailed = "Couldn’t stop it. Try on your iPhone."
    static func until(_ date: Date) -> String {
        "until " + date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "en_GB")))
    }
}

struct WatchHome: View {
    let model: WatchModel

    var body: some View {
        #if DEBUG
        // For looking at the request card in the simulator: -SampleCard YES (-SamplePractice YES for the practice's).
        if UserDefaults.standard.bool(forKey: "SampleCard") { SampleCard() } else { home }
        #else
        home
        #endif
    }

    private var home: some View {
        // "In use" while something is in use; otherwise the page for where setup stands.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let inUse = model.inUse.filter { $0.until > context.date }
            if model.setup == .ready && !inUse.isEmpty { WatchInUseList(items: inUse) } else { WatchSetupPage(setup: model.setup) }
        }
    }
}

#if DEBUG
private struct SampleCard: View {
    @State private var model = RequestModel()
    var body: some View { RequestView(model: model).onAppear { model.show(["akrSample": true]) } }
}
#endif

struct WatchSetupPage: View {
    let setup: WatchSetup
    @State private var busy = false
    @State private var practiceFailed = false

    var body: some View {
        let page = WatchCopy.page(setup)
        KeyringPage(title: page.title, sentence: page.detail, alignment: .centre, mascot: mascot,
                    status: practiceFailed && setup == .addedOfferPractice ? .problem(WatchCopy.practiceNotAsked) : waiting,
                    primary: primary, secondary: secondary)
    }

    private var mascot: KeyringMascot.Mood {
        switch setup {
        case .ready, .addedOfferPractice: .approved
        case .preparing, .practiceWaiting, .settingUpNotifications: .waiting
        case .noPasscode, .notificationsOff: .offline
        default: .calm
        }
    }

    private var waiting: KeyringStatus? { nil }

    private var primary: KeyringAction? {
        switch setup {
        case .readyToAdd: action(WatchCopy.add, .advance) { await WatchLink.shared.add() }
        case .notifications:
            // watchOS's own question, only once the iPhone has added this Apple Watch.
            action(WatchCopy.continueButton, .advance) {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                await WatchLink.shared.refreshSetup()
                await WatchLink.shared.sendHandOver()
            }
        case .notificationsOff: action(WatchCopy.checkAgain, .plain) { await WatchLink.shared.refreshSetup() }
        case .addedOfferPractice: action(WatchCopy.tryPractice, .advance) { practiceFailed = !(await WatchLink.shared.askForPractice()) }
        case .practiceWaiting: action(WatchCopy.cancel, .plain) { await WatchLink.shared.cancelPractice() }
        default: nil
        }
    }

    private var secondary: KeyringAction? {
        setup == .addedOfferPractice ? action(WatchCopy.done, .plain) { await WatchLink.shared.practiceOfferDone() } : nil
    }

    private func action(_ title: String, _ kind: KeyringAction.Kind, _ run: @escaping @MainActor () async -> Void) -> KeyringAction {
        KeyringAction(title, kind, isEnabled: !busy) {
            busy = true
            Task { await run(); busy = false }
        }
    }
}

/// "In use", each approval with Stop.
struct WatchInUseList: View {
    let items: [WatchInUse]
    @State private var stopping: String?
    @State private var failed: String?

    var body: some View {
        KeyringPage(title: WatchCopy.inUse, status: failed.map { _ in .problem(WatchCopy.stopFailed) }) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: KeyringSpace.s1) {
                    KeyringText(item.site, as: .heading)
                    KeyringText("\(item.who) · \(WatchCopy.until(item.until))", as: .meta)
                    KeyringButton(.plain(WatchCopy.stop, isEnabled: stopping == nil) {
                        stopping = item.id
                        Task {
                            let stopped = await WatchLink.shared.stop(item.id)
                            failed = stopped ? nil : item.id
                            stopping = nil
                        }
                    })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
