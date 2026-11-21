// Written by AI on 2026.10.31 by model Claude Opus 5.5; rebuilt on
// 2026.11.21 by model claude opus 5.5 from the shared page parts, the copy
// ledger of 21 November and the Paper page "Agent Keyring (Holistic)", board 4.
//
// The menu bar window answers three questions: is anything waiting for me,
// what are agents using now (and can I stop it), and what happened earlier
// today. Plus a way to the passwords and the devices.

#if os(macOS)
import AgentKeyringDesign
import AppKit
import Observation
import SwiftUI

public struct MacMenuBarSnapshot: Hashable, Sendable {
    /// Waiting, in use and recent requests, in any order.
    public var requests: [AccessRequest]
    /// Computers and devices waiting to join.
    public var enrolments: [DeviceEnrolment]
    /// Tailscale is off on this Mac while an iPhone or Apple Watch is added:
    /// requests can't reach them.
    public var offline: Bool
    public var passwordCount: Int

    public init(requests: [AccessRequest], enrolments: [DeviceEnrolment] = [], offline: Bool = false, passwordCount: Int = 0) {
        self.requests = requests
        self.enrolments = enrolments
        self.offline = offline
        self.passwordCount = passwordCount
    }
}

@MainActor
public protocol MacMenuBarBackend: AnyObject {
    /// The current snapshot first, then one each time anything changes.
    func updates() -> AsyncStream<MacMenuBarSnapshot>
    /// Stop: Josh ends an agent's access early.
    func endAccess(requestID: String) async throws -> AccessRequestState
    /// Clears a denial's hold-off, so that computer may ask for the password again.
    func allowAskingAgain(requestID: String) async throws -> AccessRequestState
}

@MainActor
@Observable
public final class MacMenuBarModel {
    public private(set) var snapshot: MacMenuBarSnapshot
    public var review: (String) -> Void = { _ in }
    public var reviewEnrolment: (String) -> Void = { _ in }
    public var openDevices: () -> Void = {}
    public var openPasswords: () -> Void = {}
    public var copyAgain: () -> Void = {}
    public var quit: () -> Void = {}

    private let backend: any MacMenuBarBackend

    public init(backend: any MacMenuBarBackend, initial: MacMenuBarSnapshot) {
        self.snapshot = initial
        self.backend = backend
    }

    /// Follows the backend for as long as the app runs. Start it once at launch,
    /// not from the window, so the window is ready when the icon is clicked.
    public func followUpdates() async {
        for await next in backend.updates() { snapshot = next }
    }

    public var waiting: [AccessRequest] { snapshot.requests.filter(\.state.isWaitingForYou) }
    public var inUse: [AccessRequest] { snapshot.requests.filter(\.state.isInUse) }
    public var earlierToday: [AccessRequest] {
        Array(snapshot.requests.filter { !$0.state.isWaitingForYou && !$0.state.isInUse && Calendar.current.isDateInToday($0.askedAt) }
            .sorted { $0.askedAt > $1.askedAt }.prefix(4))
    }

    /// Requests and joins waiting for him.
    public var waitingCount: Int { waiting.count + snapshot.enrolments.count }

    public func endAccess(_ id: String) async {
        guard let state = try? await backend.endAccess(requestID: id) else { return }
        update(id, to: state)
    }

    public func allowAskingAgain(_ id: String) async {
        guard let state = try? await backend.allowAskingAgain(requestID: id) else { return }
        update(id, to: state)
    }

    private func update(_ id: String, to state: AccessRequestState) {
        guard let index = snapshot.requests.firstIndex(where: { $0.id == id }) else { return }
        snapshot.requests[index].state = state
    }
}

/// The icon in the menu bar: the keyhole, drawn as a template so macOS
/// colours it for a light or dark menu bar.
public struct MacMenuBarLabel: View {
    public init() {}

    public var body: some View {
        Image(nsImage: Self.keyhole).accessibilityLabel(SetupCopy.appName)
    }

    static let keyhole: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let s = rect.width / 80
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: (x - 10) * s, y: (y - 12) * s) }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: (50 - 21.5 - 10) * s, y: (38.5 - 21.5 - 12) * s, width: 43 * s, height: 43 * s)).fill()
            let body = NSBezierPath()
            body.move(to: p(40.2, 51.5)); body.line(to: p(59.8, 51.5)); body.line(to: p(67.2, 81.9))
            body.line(to: p(64.1, 85.9)); body.line(to: p(35.9, 85.9)); body.line(to: p(32.8, 81.9)); body.close()
            body.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// "Agent Keyring stays here.", under the menu bar icon after first run's Done.
public struct MenuBarTipView: View {
    public init() {}

    public var body: some View {
        Text(FirstRunCopy.staysHere).font(.system(size: 13)).foregroundStyle(RequestToken.ink)
            .fixedSize()
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RequestToken.surface, in: .rect(cornerRadius: 10))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 8)
            .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
            .padding(16)
    }
}

/// The window under the keyhole. Its width is the app's to set.
public struct MacMenuBarView: View {
    let model: MacMenuBarModel

    public init(model: MacMenuBarModel) {
        self.model = model
    }

    public var body: some View {
        KeyringMenuBarWindow {
            header
            if model.snapshot.offline {
                KeyringHint(symbol: "wifi.slash", MenuBarCopy.offlineNotice, tone: .stalled)
            }
            if model.waitingCount > 0 {
                KeyringSection(MenuBarCopy.waitingForYou) {
                    ForEach(model.snapshot.enrolments) { enrolment in
                        KeyringDeviceRow(symbol: enrolment.kind == .machine ? "desktopcomputer" : "iphone", name: enrolment.name,
                                         detail: SetupCopy.joiningDetail(enrolment)) {
                            KeyringButton(.plain(MenuBarCopy.show) { model.reviewEnrolment(enrolment.id) })
                        }
                    }
                    ForEach(model.waiting) { request in
                        KeyringDeviceRow(symbol: "hourglass", name: request.login.site, detail: MenuBarCopy.waitingDetail(request), nameFit: .siteName) {
                            KeyringButton(.plain(MenuBarCopy.show) { model.review(request.id) })
                        }
                    }
                }
            }
            if !model.inUse.isEmpty {
                KeyringSection(MenuBarCopy.inUse) {
                    ForEach(model.inUse) { request in
                        // Stop here ends this Mac's own agents' access; another computer's is stopped from the iPhone.
                        KeyringDeviceRow(symbol: "key.fill", name: request.login.site, detail: MenuBarCopy.inUseDetail(request), nameFit: .siteName) {
                            if request.agent.isLocal {
                                KeyringButton(.plain(MenuBarCopy.stop) { Task { await model.endAccess(request.id) } })
                            }
                        }
                    }
                }
            }
            if model.waitingCount == 0 && model.inUse.isEmpty {
                // The same card shape and margins as the offline notice above it.
                KeyringHint(symbol: "tray", MenuBarCopy.nothing, tone: .plain)
            }
            if !model.earlierToday.isEmpty {
                KeyringSection(MenuBarCopy.earlierToday) {
                    ForEach(model.earlierToday) { request in
                        let outcome = Self.outcome(request)
                        KeyringDeviceRow(symbol: outcome.symbol, name: MenuBarCopy.earlier(request), detail: outcome.word, tone: outcome.tone)
                            .contextMenu {
                                if request.agent.isLocal && request.state.isHoldingOffNewRequests(now: .now) {
                                    Button(MenuBarCopy.letAskAgain) { Task { await model.allowAskingAgain(request.id) } }
                                }
                            }
                    }
                }
            }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: KeyringSpace.s2) {
            KeyringMascot(model.snapshot.offline ? .offline : model.waitingCount > 0 ? .curious : .calm)
                .frame(width: KeyringSpace.s6, height: KeyringSpace.s6)
            KeyringText(MenuBarCopy.appName, as: .heading)
            Spacer(minLength: KeyringSpace.s2)
            if model.snapshot.offline {
                KeyringPill(MenuBarCopy.offline, tone: .offline)
            } else if model.waitingCount > 0 {
                KeyringPill(MenuBarCopy.waiting(model.waitingCount), tone: .waiting)
            } else {
                KeyringPill(MenuBarCopy.allQuiet, tone: .calm)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: KeyringSpace.s2) {
            KeyringButton(.plain(MenuBarCopy.passwords(model.snapshot.passwordCount), perform: model.openPasswords))
            KeyringButton(.plain(MenuBarCopy.devices, perform: model.openDevices))
            Spacer(minLength: 0)
            Menu {
                Button(MenuBarCopy.copyAgain, action: model.copyAgain)
                Divider()
                Button(MenuBarCopy.quit, action: model.quit)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(MenuBarCopy.more)
        }
    }

    /// How a request earlier today ended: its word, symbol and colour.
    static func outcome(_ request: AccessRequest) -> (word: String, symbol: String, tone: KeyringDeviceRow<EmptyView>.Tone) {
        if request.byAutomaticRule { return (MenuBarCopy.automatic, "bolt.circle.fill", .waiting) }
        return switch request.state {
        case .approved, .released, .expired: (MenuBarCopy.approved, "checkmark.circle.fill", .approved)
        case .denied: (MenuBarCopy.denied, "xmark.circle.fill", .denied)
        case .ended: (MenuBarCopy.stopped, "stop.circle.fill", .plain)
        case .blockedByRule: (MenuBarCopy.blocked, "minus.circle.fill", .denied)
        case .cancelled: (MenuBarCopy.cancelled, "circle.slash", .plain)
        case .unanswered, .waitingForYou, .sendingAnswer, .waitingForMac: (MenuBarCopy.noAnswer, "clock", .plain)
        }
    }
}
#endif
