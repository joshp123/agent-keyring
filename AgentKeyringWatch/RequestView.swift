// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The request inside Apple's notification on the Watch (Paper, "The
// request", Apple Watch row, under Apple's bar): who is asking, the site, the
// account and two lines of the agent's reason, then our own Deny and Approve,
// all on the first screen of an Ultra 3. Under the buttons, reached by
// scrolling: the whole of a longer reason, and the project. Apple's Deny and
// Explain sits below. After an answer the card shows it, then closes itself.

import AgentKeyringWatchCore
import SwiftUI
import UserNotifications
import WatchKit

@MainActor @Observable
final class RequestModel {
    var request: WatchRequest?
    var unreadable = false
    var answer: String?
    var busy = false
    var dismiss: () -> Void = {}

    func show(_ userInfo: [AnyHashable: Any]) {
        answer = nil
        unreadable = false
        if let opened = try? WatchRequest.from(userInfo: userInfo, keys: WatchKeys(), saved: WatchStore().read()) {
            request = opened
            return
        }
        // The Watch may not have the latest list of devices: ask its iPhone, then read it again.
        let copy = WatchUserInfo(userInfo)
        Task {
            _ = await WatchLink.shared.askForMembers()
            // The list may also come the slow way, once the iPhone app next runs.
            for attempt in 0..<10 {
                if let opened = try? WatchRequest.from(userInfo: copy.value, keys: WatchKeys(), saved: WatchStore().read()) {
                    request = opened; unreadable = false; return
                }
                if attempt == 0 { unreadable = true }
                try? await Task.sleep(for: .seconds(1))
            }
            do { _ = try WatchRequest.from(userInfo: copy.value, keys: WatchKeys(), saved: WatchStore().read()) }
            catch { WatchLink.shared.report(problem: "The Watch could not read a request: \(error)") }
        }
    }

    func respond(approve: Bool) {
        guard let request, !busy, answer == nil else { return }
        busy = true
        Task {
            let line = await withExpiringActivity {
                do {
                    if approve { _ = try await WatchAnswers().approve(request) } else { _ = try await WatchAnswers().deny(request, words: "") }
                    return approve ? "Approved" : "Denied"
                } catch {
                    WatchLink.shared.report(problem: "\(approve ? "Approve" : "Deny") did not reach the relay: \(error)")
                    return approve ? "Not approved. Try on your iPhone." : "Not sent. Try on your iPhone."
                }
            }
            answer = line
            busy = false
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

/// Asks watchOS for time to finish sending if the wrist drops.
func withExpiringActivity<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
    let finished = DispatchSemaphore(value: 0)
    ProcessInfo.processInfo.performExpiringActivity(withReason: "Sending the answer") { expired in
        if !expired { finished.wait() }
    }
    let value = await body()
    finished.signal()
    return value
}

final class RequestController: WKUserNotificationHostingController<RequestView> {
    private let model = RequestModel()

    override class var isInteractive: Bool { true }

    override var body: RequestView { RequestView(model: model) }

    override func didReceive(_ notification: UNNotification) {
        model.dismiss = { [weak self] in self?.performDismissAction() }
        model.show(notification.request.content.userInfo)
    }
}

struct RequestView: View {
    let model: RequestModel

    private static let ink2 = Color(red: 0xA6 / 255, green: 0xA6 / 255, blue: 0xAE / 255)
    private static let deny = Color(red: 0xE5 / 255, green: 0x45 / 255, blue: 0x3D / 255)
    private static let approve = Color(red: 0x23 / 255, green: 0xA4 / 255, blue: 0x55 / 255)

    var body: some View {
        Group {
            if let request = model.request {
                content(request)
            } else if model.unreadable {
                Text("Open Agent Keyring on your iPhone to see this request.").font(.system(size: 15))
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .horizontal)
    }

    @State private var reasonCut = false

    @ViewBuilder private func content(_ request: WatchRequest) -> some View {
        VStack(spacing: 0) {
            Text(request.wants).font(.system(size: 13)).foregroundStyle(Self.ink2)
            Text(request.site).font(.system(size: 28, weight: .bold)).tracking(-0.6).lineLimit(1).minimumScaleFactor(0.7)
            if !request.account.isEmpty {
                Text(request.account).font(.system(size: 13)).foregroundStyle(Self.ink2)
            }
            if !request.reason.isEmpty {
                Text("“\(request.reason)”").font(.system(size: 15)).lineLimit(2).padding(.top, 4)
                    .background { CutCheck(text: "“\(request.reason)”", cut: $reasonCut) }
            }
            Group {
                switch request.state {
                case .ended(let outcome):
                    Text(outcome).font(.system(size: 15, weight: .semibold))
                case .waiting:
                    if let answer = model.answer {
                        Text(answer).font(.system(size: 15, weight: .semibold))
                    } else {
                        HStack(spacing: 5) {
                            button("Deny", color: Self.deny) { model.respond(approve: false) }
                            button("Approve", color: Self.approve) { model.respond(approve: true) }
                        }
                        .disabled(model.busy)
                        .padding(.horizontal, 8)
                    }
                }
            }
            .padding(.top, 8)
            if reasonCut {
                Text("“\(request.reason)”").font(.system(size: 15)).padding(.top, 20)
            }
            if let project = request.project {
                HStack(spacing: 5) {
                    Text("Project").foregroundStyle(Self.ink2)
                    Text(project).fontWeight(.semibold)
                }
                .font(.system(size: 13))
                .padding(.top, 20)
            }
        }
    }

    private func button(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(color, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Tells whether a text cut at two lines lost words: it lays the whole text
/// out at the same width, unseen, and compares the heights.
struct CutCheck: View {
    let text: String
    @Binding var cut: Bool

    var body: some View {
        GeometryReader { shown in
            Text(text).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
                .frame(width: shown.size.width).hidden()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { whole in
                    cut = whole > shown.size.height + 1
                }
        }
    }
}
