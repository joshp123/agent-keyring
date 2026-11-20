// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// The request inside Apple's notification on the Watch: who is asking, the
// site, the account and the agent's reason, short enough that Apple's own
// Approve, Deny and Deny and Explain buttons follow on the first screen.

import AgentKeyringWatchCore
import SwiftUI
import UserNotifications
import WatchKit

@MainActor @Observable
final class RequestModel {
    /// What the card shows: one state. The answer is given with Apple's buttons under it.
    enum Card {
        case opening
        /// The Watch lacks the list of devices to read it, and has asked its iPhone.
        case unreadable
        case showing(WatchRequest)
    }

    private(set) var card = Card.opening
    /// Reads the request again while the list comes from the iPhone; replaced by the next notification.
    private var reading: Task<Void, Never>?

    func show(_ userInfo: [AnyHashable: Any]) {
        reading?.cancel()
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
}

/// A notification's user info, carried across to the main actor.
struct WatchUserInfo: @unchecked Sendable {
    let value: [AnyHashable: Any]
    init(_ value: [AnyHashable: Any]) { self.value = value }
}

final class RequestController: WKUserNotificationHostingController<RequestView> {
    private let model = RequestModel()

    override var body: RequestView { RequestView(model: model) }

    override func didReceive(_ notification: UNNotification) {
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

    var body: some View {
        Group {
            switch model.card {
            case .opening: EmptyView()
            case .unreadable: Text("Open Agent Keyring on your iPhone to see this request.").font(.system(size: 15))
            case let .showing(request): content(request)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// Short enough that Apple's Approve sits on the first screen: each line keeps to one line, the reason to three.
    @ViewBuilder private func content(_ request: WatchRequest) -> some View {
        VStack(spacing: 1) {
            Text(request.wants).font(.system(size: 13)).foregroundStyle(Self.ink2).lineLimit(1).minimumScaleFactor(0.7)
            Text(request.site).font(.system(size: 22, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5)
            if !request.account.isEmpty {
                Text(request.account).font(.system(size: 13)).foregroundStyle(Self.ink2).lineLimit(1).truncationMode(.middle)
            }
            if !request.reason.isEmpty {
                Text("“\(request.reason)”").font(.system(size: 15)).lineLimit(3).padding(.top, 3)
            }
            if case .ended(let outcome) = request.state {
                Text(outcome).font(.system(size: 15, weight: .semibold)).padding(.top, 4)
            }
            if let project = request.project {
                Text("Project \(project)").font(.system(size: 12)).foregroundStyle(Self.ink2).lineLimit(1).padding(.top, 3)
            }
        }
    }
}

