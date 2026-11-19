// Written by AI on 2026.10.31 by model Claude Opus 5.5; rebuilt on
// 2026.11.20 by model claude opus 5.5 from the Paper board "In the menu bar".
//
// The menu bar window answers three questions: is anything waiting for me,
// what are agents using now (and can I stop it), and what happened earlier
// today. Plus a way to the passwords and the devices.

#if os(macOS)
import AppKit
import Observation
import SwiftUI

public struct MacMenuBarSnapshot: Hashable, Sendable {
    /// Waiting, in use and recent requests, local and remote, in any order.
    public var requests: [AccessRequest]
    /// Computers and devices waiting to join.
    public var enrolments: [DeviceEnrolment]
    /// The computer that stays on, while this Mac cannot reach it.
    public var offlineComputer: String?
    public var passwordCount: Int
    public var taskHistoryNeedsReset: Bool

    public init(requests: [AccessRequest], enrolments: [DeviceEnrolment] = [], offlineComputer: String? = nil,
        passwordCount: Int = 0, taskHistoryNeedsReset: Bool = false) {
        self.requests = requests
        self.enrolments = enrolments
        self.offlineComputer = offlineComputer
        self.passwordCount = passwordCount
        self.taskHistoryNeedsReset = taskHistoryNeedsReset
    }
}

@MainActor
public protocol MacMenuBarBackend: AnyObject {
    /// The current snapshot first, then one each time anything changes.
    func updates() -> AsyncStream<MacMenuBarSnapshot>
    /// Josh ends an agent's access early. The lease becomes REVOKED.
    func endAccess(requestID: String) async throws -> AccessRequestState
    /// Clears a denial's hold-off, so that machine may ask for the login again.
    func allowAskingAgain(requestID: String) async throws -> AccessRequestState
}

@MainActor
@Observable
public final class MacMenuBarModel {
    public private(set) var requests: [AccessRequest]
    public private(set) var enrolments: [DeviceEnrolment]
    public private(set) var offlineComputer: String?
    public private(set) var passwordCount: Int
    public private(set) var taskHistoryNeedsReset: Bool
    public var review: (String) -> Void = { _ in }
    public var reviewEnrolment: (String) -> Void = { _ in }
    public var openMachines: () -> Void = {}
    public var openRules: () -> Void = {}
    public var openAgentKeyring: () -> Void = {}
    public var quit: () -> Void = {}

    private let backend: any MacMenuBarBackend

    public init(backend: any MacMenuBarBackend, initial: MacMenuBarSnapshot) {
        self.requests = initial.requests
        self.enrolments = initial.enrolments
        self.offlineComputer = initial.offlineComputer
        self.passwordCount = initial.passwordCount
        self.taskHistoryNeedsReset = initial.taskHistoryNeedsReset
        self.backend = backend
    }

    /// Everything that needs Josh: waiting requests, devices waiting to join,
    /// and agents paused on this Mac.
    public var attentionCount: Int { waiting.count + enrolments.count + (taskHistoryNeedsReset ? 1 : 0) }

    /// Follows the backend for as long as the app runs. Start it once at launch,
    /// not from the window, because the menu bar icon shows the waiting count.
    public func followUpdates() async {
        for await snapshot in backend.updates() {
            requests = snapshot.requests
            enrolments = snapshot.enrolments
            offlineComputer = snapshot.offlineComputer
            passwordCount = snapshot.passwordCount
            taskHistoryNeedsReset = snapshot.taskHistoryNeedsReset
        }
    }

    public var waiting: [AccessRequest] { requests.filter(\.state.isWaitingForYou) }
    public var inUse: [AccessRequest] { requests.filter(\.state.isInUse) }
    public var recent: [AccessRequest] {
        Array(requests.filter { !$0.state.isWaitingForYou && !$0.state.isInUse && Calendar.current.isDateInToday($0.askedAt) }
            .sorted { $0.askedAt > $1.askedAt }.prefix(4))
    }

    public func endAccess(_ id: String) async {
        guard let state = try? await backend.endAccess(requestID: id) else { return }
        update(id, to: state)
    }

    public func allowAskingAgain(_ id: String) async {
        guard let state = try? await backend.allowAskingAgain(requestID: id) else { return }
        update(id, to: state)
    }

    private func update(_ id: String, to state: AccessRequestState) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].state = state
    }
}

/// The icon in the menu bar: the keyhole, drawn as a template so macOS
/// colours it for a light or dark menu bar.
public struct MacMenuBarLabel: View {
    public init() {}

    public var body: some View {
        Image(nsImage: Self.keyhole).accessibilityLabel("Agent Keyring")
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
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RequestToken.surface, in: .rect(cornerRadius: 10))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 8)
            .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
            .padding(16)
    }
}

public struct MacMenuBarView: View {
    let model: MacMenuBarModel

    public init(model: MacMenuBarModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let computer = model.offlineComputer { Banner(text: MenuBarCopy.offline(computer)) }
            if model.taskHistoryNeedsReset {
                Banner(text: MenuBarCopy.paused) {
                    Pill(title: MenuBarCopy.reset, dark: true, action: model.openAgentKeyring).padding(.top, 8)
                }
            }
            if !model.waiting.isEmpty || !model.enrolments.isEmpty {
                Heading(MenuBarCopy.waitingForYou)
                ForEach(model.enrolments) { enrolment in
                    Row(title: enrolment.name, detail: SetupCopy.joiningDetail(enrolment)) {
                        Pill(title: MenuBarCopy.show, dark: true) { model.reviewEnrolment(enrolment.id) }
                    }
                }
                ForEach(model.waiting) { request in
                    Row(title: request.login.site, detail: MenuBarCopy.who(request)) {
                        Pill(title: MenuBarCopy.show, dark: true) { model.review(request.id) }
                    }
                }
            }
            if !model.inUse.isEmpty {
                Heading(MenuBarCopy.inUse)
                ForEach(model.inUse) { request in
                    Row(title: request.login.site, detail: MenuBarCopy.inUseDetail(request)) {
                        Pill(title: MenuBarCopy.stop, dark: false) { Task { await model.endAccess(request.id) } }
                    }
                }
            }
            if model.attentionCount == 0 && model.inUse.isEmpty {
                Text(MenuBarCopy.nothing).font(.system(size: 14)).foregroundStyle(RequestToken.ink2)
                    .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
            }
            if !model.recent.isEmpty {
                Heading(MenuBarCopy.earlierToday)
                ForEach(model.recent) { request in
                    RecentRow(request: request) { Task { await model.allowAskingAgain(request.id) } }
                }
            }
            Color.clear.frame(height: 8)
            footer
        }
        .frame(width: 380)
        .background(RequestToken.surface)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Pill(title: MenuBarCopy.passwords(model.passwordCount), dark: false, inset: 12, action: model.openRules)
                .accessibilityIdentifier("menu-rules")
            Pill(title: MenuBarCopy.devices, dark: false, inset: 12, action: model.openMachines)
            Spacer(minLength: 0)
            Menu {
                Button(MenuBarCopy.open, action: model.openAgentKeyring)
                Divider()
                Button(MenuBarCopy.quit, action: model.quit)
            } label: {
                Text("···").font(.system(size: 16, weight: .bold)).foregroundStyle(RequestToken.ink2)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(MenuBarCopy.more)
            .accessibilityIdentifier("menu-more")
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
        .overlay(alignment: .top) { RequestToken.line.frame(height: 1) }
    }
}

private struct Banner<Extra: View>: View {
    let text: String
    @ViewBuilder var extra: Extra

    init(text: String, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.text = text
        self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text).font(.system(size: 13)).foregroundStyle(RequestToken.ink).fixedSize(horizontal: false, vertical: true)
            extra
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RequestToken.fill, in: .rect(cornerRadius: 10))
        .padding(.horizontal, 12).padding(.top, 12)
    }
}

private struct Heading: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(RequestToken.ink2)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 3)
    }
}

private struct Row<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(RequestToken.ink).lineLimit(1)
                Text(detail).font(.system(size: 13)).foregroundStyle(RequestToken.ink2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
    }
}

private struct RecentRow: View {
    let request: AccessRequest
    let allowAskingAgain: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(AccessRequestCopy.clock(request.askedAt)).font(.system(size: 13).monospacedDigit())
                .foregroundStyle(RequestToken.ink2).frame(width: 38, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.login.site).font(.system(size: 14, weight: .semibold)).foregroundStyle(RequestToken.ink).lineLimit(1)
                Text(MenuBarCopy.who(request, project: false)).font(.system(size: 13)).foregroundStyle(RequestToken.ink2).lineLimit(1)
                if request.state.isHoldingOffNewRequests(now: .now) {
                    Button(AccessRequestCopy.letAskAgain, action: allowAskingAgain)
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(RequestToken.brand)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(request.byAutomaticRule ? MenuBarCopy.automatic : AccessRequestCopy.outcomeWord(request.state))
                    .font(.system(size: 13)).foregroundStyle(RequestToken.ink)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
    }

    private var dot: Color {
        if request.byAutomaticRule { return RequestToken.idle }
        return switch request.state {
        case .approved, .released, .expired: RequestToken.approve
        case .denied, .blockedByRule: RequestToken.deny
        default: RequestToken.idle
        }
    }
}

private struct Pill: View {
    let title: String
    let dark: Bool
    var height: CGFloat = 28
    var inset: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(dark ? RequestToken.surface : RequestToken.ink)
                .padding(.horizontal, inset).frame(height: height)
                .background(dark ? RequestToken.ink : RequestToken.fill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
#endif
