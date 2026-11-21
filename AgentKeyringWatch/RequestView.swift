// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The request inside Apple's notification on the Watch: the card from
// AgentKeyringWatchUI, and what opening and answering it does.

import AgentKeyringWatchCore
import AgentKeyringWatchUI
import SwiftUI
import UserNotifications
import WatchKit

@MainActor @Observable
final class RequestModel {
    private(set) var card = WatchCard.opening
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
    var body: some View { WatchRequestCard(card: model.card) { model.respond(approve: $0, words: $1) } }
}
