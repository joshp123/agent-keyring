// Written by AI on 2026.11.21 by model Claude Opus 5.5.
//
// Apple Watch's pages, from the shared page parts: one per state of
// WatchSetup, "In use" with Stop, and a request's card. They hold no state of
// their own beyond a button's busy moment; the app gives them what to show and
// what each button does. In a package target so the cut-off check hosts them
// (WatchGallery). Every word is in WatchCopy.

#if os(watchOS)
import AgentKeyringDesign
import AgentKeyringWatchCore
import SwiftUI

/// How an answer from the card went.
public enum WatchAnswerResult: Sendable { case sent, alreadyAnswered, failed }

/// What a request's card shows: one state, so an answer can only follow the request on screen, and only once.
public enum WatchCard: Sendable, Equatable {
    case opening
    /// The Watch lacks the list of devices to read it, and has asked its iPhone.
    case unreadable
    case showing(WatchRequest)
    case sending(WatchRequest)
    case answered(WatchRequest, String)
}

/// A request's card: who asks, the site and the account, Deny and Approve, then Deny and Explain, all before
/// the reason, so a long reason never pushes them off the screen.
public struct WatchRequestCard: View {
    let card: WatchCard
    let respond: (_ approve: Bool, _ words: String) -> Void
    /// Set by the cut-off check, which lays a scrolling page out at full length.
    @Environment(\.keyringUnrollsScrolling) private var unrolls

    public init(card: WatchCard, respond: @escaping (_ approve: Bool, _ words: String) -> Void) {
        self.card = card
        self.respond = respond
    }

    public var body: some View {
        switch card {
        case .opening: EmptyView()
        case .unreadable: KeyringPage(title: WatchCopy.unreadable, alignment: .centre)
        case let .showing(request), let .sending(request):
            if case let .ended(outcome) = request.state { ended(request, outcome, approved: false) } else { open(request) }
        case let .answered(request, line): ended(request, line, approved: line == WatchCopy.answered(approve: true, .sent))
        }
    }

    private func open(_ request: WatchRequest) -> some View {
        let sending = card == .sending(request)
        let content = KeyringApprovalCard(
                lead: request.isPractice ? WatchCopy.practiceLead : request.wants,
                subject: request.site, detail: request.account.isEmpty ? nil : request.account,
                reason: request.reason.isEmpty ? nil : request.reason,
                approve: .approve(WatchCopy.approve, isEnabled: !sending) { respond(true, "") },
                deny: .deny(WatchCopy.deny, isEnabled: !sending) { respond(false, "") },
                explain: .explain(WatchCopy.denyAndExplain, prompt: WatchCopy.whatInstead) { words in
                    let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { respond(false, trimmed) }
                })
        return Group { if unrolls { content } else { ScrollView { content } } }
    }

    private func ended(_ request: WatchRequest, _ line: String, approved: Bool) -> some View {
        KeyringPage(alignment: .centre) {
            KeyringText(request.site, as: .site, fit: .siteName)
            KeyringConfirmation(line, tone: approved ? .approved : .denied)
        }
    }
}

/// A button on a setup page.
public enum WatchSetupAction: Sendable { case add, allowNotifications, checkAgain, tryPractice, cancelPractice, done }

/// Where Apple Watch's setup stands, one page per state.
public struct WatchSetupPage: View {
    let setup: WatchSetup
    let practiceFailed: Bool
    let act: @MainActor (WatchSetupAction) async -> Void
    @State private var busy = false

    public init(setup: WatchSetup, practiceFailed: Bool = false, act: @escaping @MainActor (WatchSetupAction) async -> Void) {
        self.setup = setup
        self.practiceFailed = practiceFailed
        self.act = act
    }

    public var body: some View {
        let page = WatchCopy.page(setup)
        KeyringPage(title: page.title, sentence: page.detail, alignment: .centre, mascot: mascot,
                    status: practiceFailed && setup == .addedOfferPractice ? .problem(WatchCopy.practiceNotAsked) : nil,
                    primary: primary, secondary: setup == .addedOfferPractice ? action(WatchCopy.done, .plain, .done) : nil)
    }

    private var mascot: KeyringMascot.Mood {
        switch setup {
        case .ready, .addedOfferPractice: .approved
        case .preparing, .practiceWaiting, .settingUpNotifications: .waiting
        case .noPasscode, .notificationsOff: .offline
        default: .calm
        }
    }

    private var primary: KeyringAction? {
        switch setup {
        case .readyToAdd: action(WatchCopy.add, .advance, .add)
        case .notifications: action(WatchCopy.continueButton, .advance, .allowNotifications)
        case .notificationsOff: action(WatchCopy.checkAgain, .plain, .checkAgain)
        case .addedOfferPractice: action(WatchCopy.tryPractice, .advance, .tryPractice)
        case .practiceWaiting: action(WatchCopy.cancel, .plain, .cancelPractice)
        default: nil
        }
    }

    private func action(_ title: String, _ kind: KeyringAction.Kind, _ what: WatchSetupAction) -> KeyringAction {
        KeyringAction(title, kind, isEnabled: !busy) {
            busy = true
            Task { await act(what); busy = false }
        }
    }
}

/// "In use", each approval with Stop.
public struct WatchInUsePage: View {
    let items: [WatchInUse]
    let stop: @MainActor (String) async -> Bool
    @State private var stopping: String?
    @State private var failed: String?

    public init(items: [WatchInUse], stop: @escaping @MainActor (String) async -> Bool) {
        self.items = items
        self.stop = stop
    }

    public var body: some View {
        KeyringPage(title: WatchCopy.inUse, status: failed.map { _ in .problem(WatchCopy.stopFailed) }) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: KeyringSpace.s1) {
                    KeyringText(item.site, as: .site, fit: .siteName)
                    KeyringText("\(item.who) · \(WatchCopy.until(item.until))", as: .meta)
                    KeyringButton(.plain(WatchCopy.stop, isEnabled: stopping == nil) {
                        stopping = item.id
                        Task {
                            failed = await stop(item.id) ? nil : item.id
                            stopping = nil
                        }
                    })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Every Watch page in each state worth seeing, with the longest words it will hold, for the cut-off check.
@MainActor
public enum WatchGallery {
    static let longRequest = WatchRequest(
        work: Data(), id: "r1", site: "accounts.longcompany-example.co.uk", account: "firstname.lastname+work@company.example",
        sites: [], agent: "Claude Code", wants: "Claude Code on MacBook Pro (16-inch) wants", project: "bookkeeping",
        reason: "You asked me to download October’s invoice from the billing page and file it in the bookkeeping folder for the accountant.",
        state: .waiting, who: "Claude Code on MacBook Pro", inUseUntil: nil, isPractice: false)
    static let practice = WatchRequest(
        work: Data(), id: "p1", site: "example.com", account: "you@example.com", sites: [], agent: "Agent Keyring",
        wants: "Practice: an agent wants", project: nil, reason: "You asked me to download October’s invoice.",
        state: .waiting, who: "Practice", inUseUntil: nil, isPractice: true)

    public static var entries: [KeyringGalleryEntry] {
        let setups: [(String, WatchSetup)] = [
            ("no-passcode", .noPasscode), ("set-up-iphone", .setUpIPhone), ("start-on-iphone", .startOnIPhone),
            ("ready-to-add", .readyToAdd), ("preparing", .preparing), ("notifications", .notifications),
            ("notifications-off", .notificationsOff), ("setting-up", .settingUpNotifications),
            ("added", .addedOfferPractice), ("practice-waiting", .practiceWaiting), ("ready", .ready),
        ]
        return setups.map { name, setup in KeyringGalleryEntry("watch-setup-\(name)", .watch) { WatchSetupPage(setup: setup) { _ in } } } + [
            KeyringGalleryEntry("watch-setup-added-practice-failed", .watch) { WatchSetupPage(setup: .addedOfferPractice, practiceFailed: true) { _ in } },
            KeyringGalleryEntry("watch-request", .watch) { WatchRequestCard(card: .showing(longRequest)) { _, _ in } },
            KeyringGalleryEntry("watch-request-practice", .watch) { WatchRequestCard(card: .showing(practice)) { _, _ in } },
            KeyringGalleryEntry("watch-request-unreadable", .watch) { WatchRequestCard(card: .unreadable) { _, _ in } },
            KeyringGalleryEntry("watch-request-approved", .watch) {
                WatchRequestCard(card: .answered(longRequest, WatchCopy.answered(approve: true, .sent))) { _, _ in }
            },
            KeyringGalleryEntry("watch-request-already-answered", .watch) {
                WatchRequestCard(card: .answered(longRequest, WatchCopy.answered(approve: true, .alreadyAnswered))) { _, _ in }
            },
            KeyringGalleryEntry("watch-request-not-sent", .watch) {
                WatchRequestCard(card: .answered(longRequest, WatchCopy.answered(approve: false, .failed))) { _, _ in }
            },
            KeyringGalleryEntry("watch-in-use", .watch) {
                WatchInUsePage(items: [WatchInUse(id: "u1", site: "accounts.longcompany-example.co.uk", who: "Claude Code on MacBook Pro",
                                                  until: Date(timeIntervalSince1970: 1_795_000_000))]) { _ in true }
            },
        ]
    }
}
#endif
