// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The request inside Apple's notification on the Watch: who is asking, the
// site and the account, Deny and Approve, the agent's whole reason, then Deny
// and Explain. Our three buttons, one kind.

import AgentKeyringDesign
import AgentKeyringWatchCore
import SwiftUI
import UserNotifications
import WatchKit

@MainActor @Observable
final class RequestModel {
    /// What the card shows: one state, so an answer can only follow the request on screen, and only once.
    enum Card {
        case opening
        /// The Watch lacks the list of devices to read it, and has asked its iPhone.
        case unreadable
        case showing(WatchRequest)
        case sending(WatchRequest)
        case answered(WatchRequest, String)
    }

    private(set) var card = Card.opening
    var dismiss: () -> Void = {}
    /// Reads the request again while the list comes from the iPhone; replaced by the next notification.
    private var reading: Task<Void, Never>?

    func show(_ userInfo: [AnyHashable: Any]) {
        reading?.cancel()
        #if DEBUG
        if userInfo["akrSample"] != nil { card = .showing(.sample); return }
        #endif
        do {
            let opened = try WatchRequest.from(userInfo: userInfo, keys: WatchKeys(), saved: WatchStore().read())
            card = .showing(opened)
            watchLog.note("card", "shown", ["request": opened.id])
            return
        } catch {
            watchLog.note("card", "unreadable", ["error": "\(error)"])
        }
        card = .opening
        // The Watch may not have the latest list of devices: ask its iPhone, then read it again.
        let copy = WatchUserInfo(userInfo)
        reading = Task {
            _ = await WatchLink.shared.askForMembers()
            // The list may also come the slow way, once the iPhone app next runs.
            for attempt in 0..<10 {
                guard !Task.isCancelled else { return }
                if let opened = try? WatchRequest.from(userInfo: copy.value, keys: WatchKeys(), saved: WatchStore().read()) {
                    card = .showing(opened)
                    watchLog.note("card", "shown", ["request": opened.id, "after": "\(attempt) s"])
                    return
                }
                if attempt == 0 { card = .unreadable }
                try? await Task.sleep(for: .seconds(1))
            }
            do { _ = try WatchRequest.from(userInfo: copy.value, keys: WatchKeys(), saved: WatchStore().read()) }
            catch { WatchLink.shared.report(problem: "The Watch could not read a request: \(error)") }
        }
    }

    func close() { reading?.cancel() }

    var isSending: Bool { if case .sending = card { true } else { false } }

    /// Approve, Deny, or Deny with his words: sent once, the line shown, then the card closes.
    func respond(approve: Bool, words: String = "") {
        guard case let .showing(request) = card else { return }
        card = .sending(request)
        Task {
            let result = await WatchDelegate.answer(request, approve: approve, words: words)
            card = .answered(request, WatchCopy.answered(approve: approve, result))
            try? await Task.sleep(for: .seconds(1.2))
            dismiss()
        }
    }
}

/// A notification's user info, carried across to the main actor.
struct WatchUserInfo: @unchecked Sendable {
    let value: [AnyHashable: Any]
    init(_ value: [AnyHashable: Any]) { self.value = value }
}

final class RequestController: WKUserNotificationHostingController<RequestView> {
    private let model = RequestModel()

    override var body: RequestView { RequestView(model: model) }

    override class var isInteractive: Bool { true }

    override func didReceive(_ notification: UNNotification) {
        model.dismiss = { [weak self] in self?.performDismissAction() }
        model.show(notification.request.content.userInfo)
    }

    override func didDeactivate() {
        model.close()
        super.didDeactivate()
    }
}

struct RequestView: View {
    let model: RequestModel

    var body: some View {
        switch model.card {
        case .opening: EmptyView()
        case .unreadable: KeyringPage(title: WatchCopy.unreadable, alignment: .centre)
        case let .showing(request), let .sending(request): open(request)
        case let .answered(request, line): ended(request, line)
        }
    }

    /// The card: who asks, the site and the account, Deny and Approve before the reason, so a long reason
    /// never pushes them off the screen. Deny and Explain is watchOS's own text input until the shared card has it.
    @ViewBuilder private func open(_ request: WatchRequest) -> some View {
        if case let .ended(outcome) = request.state {
            ended(request, outcome)
        } else {
            ScrollView {
                VStack(spacing: KeyringSpace.s2) {
                    KeyringApprovalCard(
                        lead: request.isPractice ? WatchCopy.practiceLead : request.wants,
                        subject: request.site, detail: request.account.isEmpty ? nil : request.account,
                        reason: request.reason.isEmpty ? nil : request.reason,
                        approve: .approve(WatchCopy.approve, isEnabled: !model.isSending) { model.respond(approve: true) },
                        deny: .deny(WatchCopy.deny, isEnabled: !model.isSending) { model.respond(approve: false) })
                    TextFieldLink(prompt: Text(WatchCopy.whatInstead)) {
                        KeyringText(WatchCopy.denyAndExplain, as: .label).frame(maxWidth: .infinity)
                    } onSubmit: { words in
                        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { model.respond(approve: false, words: trimmed) }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(model.isSending)
                }
            }
        }
    }

    private func ended(_ request: WatchRequest, _ line: String) -> some View {
        KeyringPage(title: request.site, alignment: .centre) {
            KeyringConfirmation(line, tone: line == WatchCopy.answered(approve: true, .sent) ? .approved : .denied)
        }
    }
}
