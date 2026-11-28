// Written by AI on 2026.11.20 by model claude opus 5.5; the Mac password
// mode and a missing Touch ID keyboard added on 2026.11.23 by the same model.
//
// What this Mac can approve with right now: a closed lid turns Touch ID off,
// a Mac with Touch ID but no fingerprint cannot approve until one is added,
// and a Mac whose Touch ID keyboard is gone cannot approve until it is back
// (or a Watch can). A Mac that approves with its password always can. What
// macOS reports is read again when the screens change (the lid), the Mac
// wakes, or the app becomes active (a fingerprint added, a keyboard back);
// the first-run window, the request panel and the presenter all read it.

#if os(macOS)
import AgentKeyringApprovalCore
import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class MacApprover {

    public static let shared = MacApprover()
    /// What macOS reported when last read.
    public internal(set) var probe: MacProbe
    /// This Mac's mode as its keys were made (`MacApprovalMode.current`): before they exist, Touch ID or the Watch.
    public internal(set) var mode: MacApprovalMode
    public var state: MacApproverState { Self.state(mode: mode, probe) }
    /// What approves on this Mac now, for the green button's words.
    public var approver: MacApproverKind { Self.approver(mode: mode, probe) }
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(mode: MacApprovalMode = MacApprovalMode.current, probe: MacProbe = MacProbe.readMacProbe()) {
        self.mode = mode
        self.probe = probe
    }

    /// Follows the lid, waking, fingerprints, keyboards and this Mac's keys for as long as the app runs.
    public func follow() {
        guard observers.isEmpty else { return }
        let reread: @Sendable (Notification) -> Void = { _ in MainActor.assumeIsolated { MacApprover.shared.refresh() } }
        for name in [NSApplication.didChangeScreenParametersNotification, NSApplication.didBecomeActiveNotification, MacApprovalMode.changed] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: reread))
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
            queue: .main, using: reread))
        refresh()
    }

    /// Reads macOS and the mode again; changes only what changed, so nothing is drawn again for nothing.
    public func refresh() {
        let probe = MacProbe.readMacProbe()
        if probe != self.probe { self.probe = probe }
        if MacApprovalMode.current != mode { mode = MacApprovalMode.current }
    }

    nonisolated static func state(mode: MacApprovalMode, _ probe: MacProbe) -> MacApproverState { MacApproverState(mode: mode, probe) }

    nonisolated static func approver(mode: MacApprovalMode, _ probe: MacProbe) -> MacApproverKind { MacApproverKind(mode: mode, probe) }

    /// The symbol beside "approve … beside this window".
    public nonisolated static var symbol: String { MacApprovalMode.current == .devicePassword ? "key.fill" : "touchid" }

    /// System Settings at Touch ID & Password.
    public nonisolated static let touchIDSettings = URL(string: "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension")!
}

/// Presentation policy for the Mac floating approval panel.
public enum ApprovalPresentationPolicy {
    /// Do not auto-pop a floating overlay when this Mac cannot approve locally and
    /// the request has already been pushed to iPhone or Apple Watch.
    public nonisolated static func shouldAutoPresent(
        isRequest: Bool,
        approverState: MacApproverState,
        approvesElsewhere: Bool
    ) -> Bool {
        guard isRequest else { return true }
        return approverState == .ready || !approvesElsewhere
    }

    /// How long an answered panel stays up before dismissing: immediately for practice
    /// requests or answers completed on another device, and briefly (1 s) for local answers.
    public nonisolated static func dismissLinger(
        isSelfTest: Bool,
        answeredElsewhere: Bool
    ) -> Duration {
        if isSelfTest || answeredElsewhere { return .zero }
        return .seconds(1)
    }
}
#endif
