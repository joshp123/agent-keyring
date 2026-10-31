// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Mock data for the Mac screens, and a host that shows one of them the way
// the app would, for the screenshots in docs/design/screens/mac.

#if os(macOS)
import AppKit
import LocalAuthentication
import SwiftUI

public enum MacDesignScreen: String, CaseIterable, Sendable {
    case approval
    case approvalReply
    case approvalApproved
    case approvalDenied
    case approvalAgentProcess
    case menuBar
    case menuBarQuiet
    case rules
    case rulesAll
    case rulesConfirm
}

@MainActor
public final class MacDesignGallery {
    private let screen: MacDesignScreen
    private var windows: [NSWindow] = []
    private let now = Date.now

    public init(screen: MacDesignScreen) {
        self.screen = screen
    }

    public func show() {
        showBackdrop()
        switch screen {
        case .approval, .approvalReply, .approvalApproved, .approvalDenied, .approvalAgentProcess:
            showApprovalPanel()
        case .menuBar, .menuBarQuiet:
            showMenuBar()
        case .rules, .rulesAll, .rulesConfirm:
            showRules()
        }
    }

    /// A plain backdrop so screenshots don't show whatever is on the desktop.
    private func showBackdrop() {
        guard let frame = NSScreen.main?.frame else { return }
        let backdrop = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.88, alpha: 1)
        }
        // Above other apps' windows, below the menu bar and the screens shown.
        backdrop.level = .floating
        backdrop.orderFrontRegardless()
        windows.append(backdrop)
    }

    private func showApprovalPanel() {
        var request = screen == .approvalAgentProcess
            ? DesignExamples.agentProcessRead(now: now) : DesignExamples.githubSignIn(now: now)
        let reply = "Don't sign in. The invoice is already in my email, use that."
        switch screen {
        case .approvalApproved: request.state = .approved(by: .mac, until: now.addingTimeInterval(30 * 60))
        case .approvalDenied:
            request.state = .denied(by: .mac, reply: reply, askAgainAfter: now.addingTimeInterval(30 * 60))
        default: break
        }
        let model = MacApprovalModel(request: request, moreWaiting: screen == .approval ? 1 : 0,
            backend: DesignMacBackend(request: request))
        if screen == .approvalReply {
            model.isReplying = true
            model.replyDraft = reply
        }
        let controller = MacApprovalPanelController()
        controller.show(model)
        retained.append(controller)
        if let panel = NSApplication.shared.windows.last(where: { $0 is NSPanel }) { report(panel) }
    }

    private func showMenuBar() {
        let history = DesignExamples.history(now: now)
        let requests = screen == .menuBarQuiet
            ? history.filter { !$0.state.isInUse }
            : [DesignExamples.githubSignIn(now: now)] + history
        let snapshot = MacMenuBarSnapshot(requests: requests,
            passwords: ImportedPasswords(count: 542, importedAt: now.addingTimeInterval(-3 * 86_400)))
        let model = MacMenuBarModel(backend: DesignMacBackend(menuBar: snapshot), initial: snapshot)
        // Drawn like a menu bar extra window: material, rounded, under the bar.
        let panel = KeyringPanel.floating(MacMenuBarView(model: model))
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - 12, y: visible.maxY - 6))
        }
        panel.makeKeyAndOrderFront(nil)
        windows.append(panel)
        report(panel)
    }

    private func showRules() {
        let rows = DesignRules.rows(now: now)
        let confirmation = screen == .rulesConfirm
            ? RulesConfirmation(summary: "34 logins: 18 Ask, 9 Automatic, 7 Blocked.", savedRulesWereUnreadable: false)
            : nil
        let snapshot = LoginRulesSnapshot(rows: rows, confirmation: confirmation)
        let model = MacRulesModel(backend: DesignMacBackend(rules: snapshot), initial: snapshot)
        if screen != .rules {
            model.filter = .all
        } else {
            model.selection = Set(model.visibleRows.prefix(3).dropFirst().map(\.id))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 790, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Rules"
        window.contentView = NSHostingView(rootView: MacRulesView(model: model))
        // Top left, clear of the middle of the screen, where system alerts appear.
        if let visible = NSScreen.main?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 24, y: visible.maxY - 24))
        }
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        report(window)
    }

    private var retained: [AnyObject] = []

    /// Prints the window's frame in top-left screen points, once laid out.
    private func report(_ window: NSWindow) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard let screenFrame = NSScreen.main?.frame else { return }
            let frame = window.frame
            let top = screenFrame.maxY - frame.maxY
            print("FRAME \(Int(frame.minX)) \(Int(top)) \(Int(frame.width)) \(Int(frame.height))")
            fflush(stdout)
        }
    }
}

/// Answers instantly and pretends everything works. Each stream yields the
/// one snapshot it was given.
@MainActor
final class DesignMacBackend: MacApprovalBackend, MacMenuBarBackend, LoginRulesBackend {
    private let request: AccessRequest?
    private let menuBar: MacMenuBarSnapshot?
    private let rules: LoginRulesSnapshot?

    init(request: AccessRequest? = nil, menuBar: MacMenuBarSnapshot? = nil, rules: LoginRulesSnapshot? = nil) {
        self.request = request
        self.menuBar = menuBar
        self.rules = rules
    }

    private static func once<Value: Sendable>(_ value: Value?) -> AsyncStream<Value> {
        AsyncStream { continuation in
            if let value { continuation.yield(value) }
            continuation.finish()
        }
    }

    func updates(requestID: String) -> AsyncStream<AccessRequest> { Self.once(request) }
    // The mini has no Touch ID, so the gallery shows the button form of Approve.
    func embeddedTouchIDContext(requestID: String) -> LAContext? { nil }
    func updates() -> AsyncStream<MacMenuBarSnapshot> { Self.once(menuBar) }
    func updates() -> AsyncStream<LoginRulesSnapshot> { Self.once(rules) }

    func approve(requestID: String) async throws -> AccessRequestState {
        try await Task.sleep(for: .milliseconds(700))
        return .approved(by: .mac, until: .now.addingTimeInterval(RequestedAccess.longestLease))
    }

    func deny(requestID: String, reply: String?) async throws -> AccessRequestState {
        .denied(by: .mac, reply: reply, askAgainAfter: .now.addingTimeInterval(30 * 60))
    }

    func allowAskingAgain(requestID: String) async throws -> AccessRequestState {
        .denied(by: .mac, reply: nil, askAgainAfter: nil)
    }

    func confirmRules() async throws {}

    func endAccess(requestID: String) async throws -> AccessRequestState {
        .ended(at: .now)
    }

    func setRule(_ rule: LoginRule, for loginIDs: Set<UUID>) async throws {}
}

enum DesignRules {
    static func rows(now: Date) -> [LoginRuleRow] {
        let logins: [(String, String, LoginRule, Double?)] = [
            ("accounts.google.com", "josh@example.com", .blocked, nil),
            ("airbnb.com", "josh@example.com", .ask, 40),
            ("albert.nl", "josh@example.com", .automatic, 3),
            ("amazon.de", "josh@example.com", .ask, 12),
            ("appleid.apple.com", "josh@example.com", .blocked, nil),
            ("belastingdienst.nl", "josh", .blocked, nil),
            ("bol.com", "josh@example.com", .ask, 25),
            ("booking.com", "josh@example.com", .ask, 9),
            ("coolblue.nl", "josh@example.com", .automatic, 60),
            ("digid.nl", "josh", .blocked, nil),
            ("discord.com", "joshp", .ask, nil),
            ("eneco.nl", "josh@example.com", .ask, 31),
            ("example.com", "test", .automatic, 0.1),
            ("figma.com", "josh@example.com", .ask, 70),
            ("github.com", "josh@example.com", .ask, 0.01),
            ("github.com", "deploy-bot", .ask, 2),
            ("hilton.com", "josh@example.com", .ask, 1),
            ("ing.nl", "josh", .blocked, nil),
            ("instagram.com", "josh.photos", .ask, 0.07),
            ("kpn.com", "josh@example.com", .ask, 0.04),
            ("linear.app", "josh@example.com", .automatic, 5),
            ("linkedin.com", "josh@example.com", .ask, 120),
            ("ns.nl", "josh@example.com", .automatic, 0.01),
            ("opensubtitles.com", "nixflix", .automatic, 6),
            ("pacer.uscourts.gov", "josh", .ask, 9),
            ("paypal.com", "josh@example.com", .blocked, nil),
            ("plex.tv", "josh@example.com", .automatic, 2),
            ("polarsteps.com", "josh@example.com", .automatic, 17),
            ("revolut.com", "josh", .blocked, nil),
            ("spotify.com", "josh@example.com", .ask, 44),
            ("thuisbezorgd.nl", "josh@example.com", .automatic, 8),
            ("vercel.com", "josh@example.com", .ask, 13),
            ("x.com", "josh", .ask, 4),
            ("ziggo.nl", "josh@example.com", .ask, 33),
        ]
        return logins.enumerated().map { index, login in
            LoginRuleRow(
                id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index))),
                site: login.0, account: login.1, rule: login.2,
                lastUsed: login.3.map { now.addingTimeInterval(-$0 * 86_400) })
        }
    }
}
#endif
