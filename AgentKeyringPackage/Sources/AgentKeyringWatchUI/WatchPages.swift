// Written by AI on 2026.11.21 by model Claude Opus 5.5.
//
// Apple Watch's pages, from the shared page parts: one per state of
// WatchOnboardingStep, "In use" with Stop, and a request's card. They hold no state of
// their own beyond a button's busy moment; the app gives them what to show and
// what each button does. In a package target so the cut-off check hosts them
// (WatchGallery). Every word is in WatchCopy.

#if os(watchOS)
import AgentKeyringDesign
import AgentKeyringSealing
import SwiftUI

/// How an answer from the card went.
public enum WatchAnswerResult: Sendable { case sent, submitted, alreadyAnswered, failed }

/// How Stop went: the relay confirmed the approval stopped; the Stop was sent but the relay did not confirm
/// it, so it may still be in use; or it could not be sent.
public enum WatchStopResult: Sendable { case stopped, sent, failed }

/// What a request's card shows: one state, so an answer can only follow the request on screen, and only once.
public enum WatchCard: Sendable, Equatable {
    case opening
    /// The Watch lacks the list of devices to read it, and has asked its iPhone.
    case unreadable
    case showing(WatchRequest)
    case sending(WatchRequest)
    case answered(WatchRequest, String, approved: Bool = false)
}

/// A request's card: who asks, the site and the account, Deny and Approve, then Deny and Explain, all before
/// the reason, so a long reason never pushes them off the screen.
public struct WatchRequestCard: View {
    let card: WatchCard
    let notificationTopInset: CGFloat
    let respond: (_ approve: Bool, _ words: String) -> Void
    /// Set by the cut-off check, which lays a scrolling page out at full length.
    @Environment(\.keyringUnrollsScrolling) private var unrolls

    public init(
        card: WatchCard,
        notificationTopInset: CGFloat = 0,
        respond: @escaping (_ approve: Bool, _ words: String) -> Void
    ) {
        self.card = card
        self.notificationTopInset = notificationTopInset
        self.respond = respond
    }

    public var body: some View {
        Group {
            switch card {
            case .opening: KeyringPage(alignment: .centre, status: .waiting(WatchCopy.openingRequest))
            case .unreadable: KeyringPage(title: WatchCopy.unreadable, alignment: .centre)
            case let .showing(request), let .sending(request):
                if case let .ended(outcome, approved) = request.state {
                    ended(request, outcome, approved: approved)
                } else {
                    open(request)
                }
            case let .answered(request, line, approved):
                ended(request, line, approved: approved)
            }
        }
        .padding(.top, notificationTopInset)
    }

    private func open(_ request: WatchRequest) -> some View {
        let sending = card == .sending(request)
        let content = KeyringApprovalCard(
                lead: request.isPractice ? WatchCopy.practiceLead : request.wants,
                subject: request.site, detail: request.account.isEmpty ? nil : request.account,
                reason: request.reason.isEmpty ? nil : request.reason,
                approve: .approve(WatchCopy.approve, isEnabled: !sending) { respond(true, "") },
                deny: .deny(WatchCopy.deny, isEnabled: !sending) { respond(false, "") },
                explain: .explain(WatchCopy.denyAndExplain, prompt: WatchCopy.whatInstead, isEnabled: !sending) { words in
                    let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { respond(false, trimmed) }
                })
            .padding(.horizontal, KeyringSpace.s3)
            .padding(.bottom, KeyringSpace.s4)
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
public enum WatchSetupAction: Sendable { case add, cancelAdd, allowNotifications, checkAgain, tryPractice, cancelPractice, done }

/// Where Apple Watch's setup stands, one page per state.
public struct WatchSetupPage: View {
    let setup: WatchOnboardingStep
    let practiceFailed: Bool
    let addFailed: Bool
    let act: @MainActor (WatchSetupAction) async -> Void
    @State private var busyFor: WatchOnboardingStep?

    public init(setup: WatchOnboardingStep, practiceFailed: Bool = false, addFailed: Bool = false, act: @escaping @MainActor (WatchSetupAction) async -> Void) {
        self.setup = setup
        self.practiceFailed = practiceFailed
        self.addFailed = addFailed
        self.act = act
    }

    public var body: some View {
        let page = WatchCopy.page(setup)
        let isWaitingPage = setup == .preparing || setup == .practiceWaiting
        KeyringPage(title: isWaitingPage ? nil : page.title, sentence: page.detail, alignment: .centre, mascot: mascot,
                    status: isWaitingPage ? .waiting(page.title) : statusLine,
                    primary: primary, secondary: setup == .addedOfferPractice ? action(WatchCopy.done, .plain, .done) : nil)
            .onChange(of: setup) { _, _ in busyFor = nil }
    }

    private var statusLine: KeyringStatus? {
        if busyFor == .readyToAdd && setup == .readyToAdd { return .waiting(WatchCopy.page(.preparing).title) }
        if busyFor == .addedOfferPractice && setup == .addedOfferPractice { return .waiting(WatchCopy.page(.practiceWaiting).title) }
        if practiceFailed && setup == .addedOfferPractice { return .problem(WatchCopy.practiceNotAsked) }
        if addFailed && setup == .readyToAdd { return .problem(WatchCopy.addFailed) }
        return nil
    }

    private var mascot: KeyringMascotMood {
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
        case .preparing: action(WatchCopy.cancel, .plain, .cancelAdd)
        case .notifications: action(WatchCopy.continueButton, .advance, .allowNotifications)
        case .notificationsOff: action(WatchCopy.checkAgain, .plain, .checkAgain)
        case .addedOfferPractice: action(WatchCopy.tryPractice, .advance, .tryPractice)
        case .practiceWaiting: action(WatchCopy.cancel, .plain, .cancelPractice)
        default: nil
        }
    }

    private func action(_ title: String, _ kind: KeyringActionKind, _ what: WatchSetupAction) -> KeyringAction {
        let current = setup
        let isBusy = busyFor == current
        return KeyringAction(title, kind, isEnabled: !isBusy) {
            busyFor = current
            Task {
                await act(what)
                if busyFor == current { busyFor = nil }
            }
        }
    }
}

/// "In use", each approval with Stop.
public struct WatchInUsePage: View {
    let items: [WatchInUse]
    let stop: @MainActor (String) async -> WatchStopResult
    @State private var stopping: String?
    @State private var failed: String?
    @State private var sent: String?

    /// `sentFor`: an approval whose Stop is on its way, for the gallery to show that line.
    public init(items: [WatchInUse], sentFor: String? = nil, stop: @escaping @MainActor (String) async -> WatchStopResult) {
        self.items = items
        self.stop = stop
        _sent = State(initialValue: sentFor)
    }

    private var status: KeyringStatus? {
        if let failed, items.contains(where: { $0.id == failed }) { return .problem(WatchCopy.stopFailed) }
        if let sent, items.contains(where: { $0.id == sent }) { return .waiting(WatchCopy.stopSent) }
        return nil
    }

    public var body: some View {
        KeyringPage(title: WatchCopy.inUse, status: status) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: KeyringSpace.s1) {
                    KeyringText(item.site, as: .site, fit: .siteName)
                    KeyringText("\(item.who) · \(WatchCopy.until(item.until))", as: .meta)
                    KeyringButton(.plain(WatchCopy.stop, isEnabled: stopping == nil) {
                        stopping = item.id
                        Task {
                            let result = await stop(item.id)
                            failed = result == .failed ? item.id : nil
                            sent = result == .sent ? item.id : nil
                            stopping = nil
                        }
                    })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: items.map(\.id)) { _, ids in
            if let failed, !ids.contains(failed) { self.failed = nil }
            if let sent, !ids.contains(sent) { self.sent = nil }
        }
    }
}

/// Every Watch page in each state worth seeing, with the longest words it will hold, for the cut-off check.
@MainActor
public enum WatchGallery {
    static let longRequest = WatchRequest(
        envelope: Data(), id: "r1", site: "accounts.longcompany-example.co.uk", account: "firstname.lastname+work@company.example",
        sites: [], agent: "Claude Code", wants: "Claude Code on MacBook Pro (16-inch) wants", project: "bookkeeping",
        reason: "You asked me to download October’s invoice from the billing page and file it in the bookkeeping folder for the accountant.",
        state: .waiting, who: "Claude Code on MacBook Pro", inUseUntil: nil, isPractice: false)
    static let practice = WatchRequest(
        envelope: Data(), id: "p1", site: "example.com", account: "you@example.com", sites: [], agent: "Agent Keyring",
        wants: "Practice: an agent wants", project: nil, reason: "You asked me to download October’s invoice.",
        state: .waiting, who: "Practice", inUseUntil: nil, isPractice: true)

    public static var entries: [KeyringGalleryEntry] {
        let setups: [(String, WatchOnboardingStep)] = [
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
                WatchRequestCard(card: .answered(longRequest, WatchCopy.answered(approve: true, .sent), approved: true)) { _, _ in }
            },
            KeyringGalleryEntry("watch-request-already-answered", .watch) {
                WatchRequestCard(card: .answered(longRequest, WatchCopy.answered(approve: true, .alreadyAnswered))) { _, _ in }
            },
            KeyringGalleryEntry("watch-request-not-sent", .watch) {
                WatchRequestCard(card: .answered(longRequest, WatchCopy.answered(approve: false, .failed))) { _, _ in }
            },
        ]
    }
}
#endif
