// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The request inside Apple's notification on the Watch (Paper, "The
// request", Apple Watch): who is asking, the site, the account and the
// agent's reason, with our own Deny and Approve. Apple's Deny and Explain
// sits under it. The designer is redrawing this inside Apple's card; the
// project line sits under the buttons until then, so both buttons fit.

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

    func show(_ userInfo: [AnyHashable: Any]) {
        answer = nil
        do {
            request = try WatchRequest.from(userInfo: userInfo, keys: WatchKeys(), saved: WatchStore().read())
            unreadable = false
        } catch {
            request = nil
            unreadable = true
            WatchLink.shared.report(problem: "The Watch could not read a request: \(error)")
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
        }
    }
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

    @ViewBuilder private func content(_ request: WatchRequest) -> some View {
        VStack(spacing: 0) {
            Text(request.wants).font(.system(size: 13)).foregroundStyle(Self.ink2)
            Text(request.site).font(.system(size: 28, weight: .bold)).tracking(-0.6).lineLimit(1).minimumScaleFactor(0.7)
            if !request.account.isEmpty {
                Text(request.account).font(.system(size: 13)).foregroundStyle(Self.ink2)
            }
            if !request.reason.isEmpty {
                Text("“\(request.reason)”").font(.system(size: 15)).padding(.top, 4)
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
            if let project = request.project {
                HStack(spacing: 5) {
                    Text("Project").foregroundStyle(Self.ink2)
                    Text(project).fontWeight(.semibold)
                }
                .font(.system(size: 13))
                .padding(.top, 8)
            }
        }
    }

    private func button(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(color, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}
