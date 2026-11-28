// Written by AI on 2026.11.18 by model claude opus 5.5;
// decoupled from WatchConnectivity transport on 2026.11.27.
//
// The request inside Apple's notification on the Watch: the card from
// AgentKeyringWatchUI, and what opening and answering it does.

import AgentKeyringProtocol
import AgentKeyringSealing
import AgentKeyringWatchUI
import SwiftUI
import UserNotifications
import WatchKit

@MainActor
protocol WatchRequestBackend: AnyObject {
    func openRequest(_ userInfo: [AnyHashable: Any]) throws -> WatchRequest
    func askForMembers() async -> Bool
    func reportProblem(_ message: String)
    func answer(_ request: WatchRequest, approve: Bool, words: String) async -> WatchAnswerResult
}

@MainActor @Observable
final class RequestModel {
    private(set) var card = WatchCard.opening
    var notificationTopInset: CGFloat = 24
    var dismiss: () -> Void = {}
    private let backend: any WatchRequestBackend
    /// Monotonic token incremented whenever a new notification opens or closes so an in-flight
    /// answer retry or dismiss sleep from request A can never overwrite or dismiss request B.
    private var generation: UInt64 = 0
    /// Reads the request again while the list comes from the iPhone; replaced by the next notification.
    private var reading: Task<Void, Never>?
    /// Tracks the active answer/dismiss task so close() or a replacement notification cancels it cleanly.
    private var responding: Task<Void, Never>?

    init(backend: any WatchRequestBackend = LiveWatchRequestBackend()) {
        self.backend = backend
    }

    func show(_ userInfo: [AnyHashable: Any]) {
        generation &+= 1
        let token = generation
        reading?.cancel()
        responding?.cancel()
        do {
            let opened = try backend.openRequest(userInfo)
            card = .showing(opened)
            KeyringDiagnosticLog.watch.noteDeviceEvent("card", "shown", ["request": opened.id])
            return
        } catch {
            KeyringDiagnosticLog.watch.noteDeviceEvent("card", "unreadable", ["error": "\(error)"])
        }
        card = .opening
        // The Watch may not have the latest list of devices: ask its iPhone, then read it again.
        let copy = WatchUserInfo(userInfo)
        reading = Task {
            let promptTimer = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, self.generation == token, self.card == .opening else { return }
                self.card = .unreadable
            }
            defer { promptTimer.cancel() }
            _ = await backend.askForMembers()
            // The list may also come the slow way, once the iPhone app next runs.
            for attempt in 0..<10 {
                guard !Task.isCancelled, self.generation == token else { return }
                if let opened = try? backend.openRequest(copy.value) {
                    card = .showing(opened)
                    KeyringDiagnosticLog.watch.noteDeviceEvent("card", "shown", ["request": opened.id, "after": "\(attempt) s"])
                    return
                }
                if attempt == 0 { card = .unreadable }
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, self.generation == token else { return }
            do { _ = try backend.openRequest(copy.value) }
            catch { backend.reportProblem("The Watch could not read a request: \(error)") }
        }
    }

    func close() {
        generation &+= 1
        reading?.cancel()
        responding?.cancel()
    }

    var isSending: Bool { if case .sending = card { true } else { false } }

    /// Approve, Deny, or Deny with his words: sent once, the line shown, then the card closes.
    func respond(approve: Bool, words: String = "") {
        guard case let .showing(request) = card else { return }
        let token = generation
        card = .sending(request)
        responding?.cancel()
        responding = Task {
            let result = await backend.answer(request, approve: approve, words: words)
            guard !Task.isCancelled, self.generation == token else { return }
            let approved = approve && (result == .sent || result == .submitted)
            card = .answered(request, WatchCopy.answered(approve: approve, result), approved: approved)
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, self.generation == token else { return }
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
        // Never inherit system or mirrored iPhone action buttons under the custom Watch card.
        notificationActions = []
        model.notificationTopInset = notification.request.content.interruptionLevel == .timeSensitive ? 24 : 12
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
        WatchRequestCard(card: model.card, notificationTopInset: model.notificationTopInset) {
            model.respond(approve: $0, words: $1)
        }
    }
}
