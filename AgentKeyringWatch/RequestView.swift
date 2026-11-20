// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The request inside Apple's notification on the Watch: who is asking, the
// site, the account and the agent's reason, then our three buttons, one kind:
// Deny and Approve on the first screen, Deny and Explain under them.

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
        if let opened = try? WatchRequest.from(userInfo: userInfo, keys: WatchKeys(), saved: WatchStore().read()) {
            card = .showing(opened)
            return
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
                    card = .showing(opened); return
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
            let sent = await WatchDelegate.answer(request, approve: approve, words: words)
            let line = sent ? (approve ? "Approved" : "Denied") : (approve ? "Not approved. Try on your iPhone." : "Not sent. Try on your iPhone.")
            card = .answered(request, line)
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

    private static let ink2 = Color(red: 0xA6 / 255, green: 0xA6 / 255, blue: 0xAE / 255)
    private static let deny = Color(red: 0xE5 / 255, green: 0x45 / 255, blue: 0x3D / 255)
    private static let approve = Color(red: 0x23 / 255, green: 0xA4 / 255, blue: 0x55 / 255)
    private static let explain = Color(red: 0x2E / 255, green: 0x2E / 255, blue: 0x31 / 255)

    var body: some View {
        Group {
            switch model.card {
            case .opening: EmptyView()
            case .unreadable: Text("Open Agent Keyring on your iPhone to see this request.").font(.system(size: 15))
            case let .showing(request), let .sending(request), let .answered(request, _): content(request)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// Short enough that Deny and Approve sit on the first screen: each line keeps to one line, the reason to two.
    @ViewBuilder private func content(_ request: WatchRequest) -> some View {
        VStack(spacing: 1) {
            Text(request.wants).font(.system(size: 13)).foregroundStyle(Self.ink2).lineLimit(1).minimumScaleFactor(0.85).truncationMode(.middle)
            Text(request.site).font(.system(size: 24, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5)
            if !request.account.isEmpty {
                Text(request.account).font(.system(size: 13)).foregroundStyle(Self.ink2).lineLimit(1).truncationMode(.middle)
            }
            if !request.reason.isEmpty {
                Text("“\(request.reason)”").font(.system(size: 15)).lineLimit(2).padding(.top, 3)
            }
            answers(request).padding(.top, 8)
            if request.reason.count > 70 {
                // The whole reason, under the buttons, for one too long for two lines.
                Text("“\(request.reason)”").font(.system(size: 15)).padding(.top, 16)
            }
            if let project = request.project {
                Text("Project \(project)").font(.system(size: 12)).foregroundStyle(Self.ink2).lineLimit(1).padding(.top, 8)
            }
        }
    }

    @ViewBuilder private func answers(_ request: WatchRequest) -> some View {
        if case .ended(let outcome) = request.state {
            Text(outcome).font(.system(size: 15, weight: .semibold))
        } else if case let .answered(_, line) = model.card {
            Text(line).font(.system(size: 15, weight: .semibold))
        } else {
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    pill("Deny", Self.deny) { model.respond(approve: false) }
                    pill("Approve", Self.approve) { model.respond(approve: true) }
                }
                // His words for the agent, from watchOS's own input (dictation, Scribble or keyboard).
                TextFieldLink(prompt: Text("What should it do instead?")) {
                    pillLabel("Deny and Explain", Self.explain)
                } onSubmit: { words in
                    let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { model.respond(approve: false, words: trimmed) }
                }
                .buttonStyle(.plain)
            }
            .disabled(model.isSending)
            .padding(.horizontal, 4)
        }
    }

    private func pill(_ title: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { pillLabel(title, color) }.buttonStyle(.plain)
    }

    private func pillLabel(_ title: String, _ color: Color) -> some View {
        Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(color, in: .capsule)
    }
}
