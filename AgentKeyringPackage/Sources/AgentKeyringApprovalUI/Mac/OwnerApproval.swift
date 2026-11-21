// Written by AI on 2026.11.16 by model Claude Opus 5.5.
//
// One action approves, where Josh is already looking: Apple's Touch ID and
// Apple Watch control sits in the window that asked, never in a macOS dialog.
// Used for rule changes, removals and sending imported logins; the request,
// connect and join panels have their own copy of the same flow.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import LocalAuthentication
import Observation
import SwiftUI

/// Touch ID or the Watch. "TouchIDOnly" (a launch argument, -TouchIDOnly YES)
/// leaves the Watch out, so a rehearsal never asks his wrist.
var ownerApprovalPolicy: LAPolicy {
    UserDefaults.standard.bool(forKey: "TouchIDOnly") ? .deviceOwnerAuthenticationWithBiometrics
        : .deviceOwnerAuthenticationWithBiometricsOrCompanion
}

@MainActor
@Observable
public final class OwnerApproval: Identifiable {
    public let id = UUID()
    /// Finishes "Touch ID or Apple Watch to …", for example "change this rule".
    public let action: String
    /// A line above the control for what Josh should know first, if anything.
    public let note: String?
    /// Shown by the Watch and in macOS's own records of the approval.
    let reason: String
    public private(set) var context: LAContext?
    public private(set) var failure: String?
    /// From the click until macOS's dialog is answered.
    public var isWaiting: Bool { task != nil }
    var timeoutDuration: Duration = .seconds(60)

    private let perform: @MainActor (LAContext) async throws -> Void
    private let finish: @MainActor (Bool) -> Void
    private var task: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var attempt = UUID()
    private var finished = false

    /// - Parameters:
    ///   - perform: runs after Josh has approved, with the evaluated context.
    ///     The context refuses any further interaction, so nothing it signs
    ///     can open a macOS dialog; it fails instead.
    ///   - finish: true once `perform` succeeded, false when Josh cancels.
    public init(action: String, note: String? = nil, reason: String, perform: @escaping @MainActor (LAContext) async throws -> Void,
        finish: @escaping @MainActor (Bool) -> Void) {
        self.action = action
        self.note = note
        self.reason = reason
        self.perform = perform
        self.finish = finish
        prepare()
    }

    /// Josh clicked: macOS's own dialog asks for Touch ID or the Watch.
    public func begin() {
        guard !finished, task == nil, let context else { return }
        let current = attempt
        timeout = Task {
            do { try await Task.sleep(for: timeoutDuration) } catch { return }
            guard attempt == current else { return }
            stop()
            failure = "Approval timed out."
        }
        task = Task {
            do {
                let approved = try await evaluate(context)
                guard approved, attempt == current else { return }
                try Task.checkCancellation()
                context.interactionNotAllowed = true
                timeout?.cancel()
                try await perform(context)
                guard attempt == current else { return }
                task = nil
                finished = true
                context.invalidate()
                self.context = nil
                finish(true)
            } catch is CancellationError {
            } catch {
                guard attempt == current else { return }
                stop()
                failure = ownerAuthenticationFailure(error, fallback: "That didn't finish. Nothing changed.")
            }
        }
    }

    private func evaluate(_ context: LAContext) async throws -> Bool {
        #if DEBUG
        if StandInKey.isOn { return true }
        #endif
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedFallbackTitle = ""
        let cancelEvaluation: @MainActor @Sendable () -> Void = { context.invalidate() }
        return try await withTaskCancellationHandler {
            try await context.evaluatePolicy(ownerApprovalPolicy, localizedReason: reason)
        } onCancel: { Task { @MainActor in cancelEvaluation() } }
    }

    public func retry() {
        guard !finished else { return }
        stop()
        prepare()
    }

    public func cancel() {
        guard !finished else { return }
        finished = true
        stop()
        finish(false)
    }

    /// The presenter is replacing or withdrawing the question. Do not call
    /// its decision callback, but ensure its context cannot approve later.
    public func invalidate() {
        guard !finished else { return }
        finished = true
        stop()
    }

    private func prepare() {
        failure = nil
        let next = LAContext()
        guard canAsk(next, ownerApprovalPolicy) else {
            failure = "Touch ID or Apple Watch isn't available. Check that one is ready."
            return
        }
        attempt = UUID()
        context = next
    }

    private func stop() {
        attempt = UUID()
        task?.cancel()
        task = nil
        timeout?.cancel()
        timeout = nil
        context?.invalidate()
        context = nil
    }
}

/// A question that needs Josh's approval and nothing else, beside his
/// window: sending password changes to the other devices, letting the
/// computers have the passwords set to Automatic on the iPhone. The same
/// card as a request: the keyhole, the question, what approving does, the
/// green button the card's full width and Not Now under it. Rebuilt on the
/// card on 2026.11.21 by model claude opus 5.5.
public struct MacQuestionPanelView: View {
    let lead: String
    let title: String
    let message: String
    let approval: OwnerApproval

    public init(lead: String, title: String, message: String, approval: OwnerApproval) {
        self.lead = lead
        self.title = title
        self.message = message
        self.approval = approval
    }

    public var body: some View {
        VStack(spacing: KeyringSpace.s3) {
            KeyringApprovalCard(lead: lead, subject: title, explanation: message, approve: approve,
                                deny: .plain(SetupCopy.notNow) { approval.cancel() }, header: SetupCopy.appName)
            if let failure = approval.failure { KeyringStatusLine(.problem(failure)) }
        }
        .padding(KeyringSpace.s5)
        .frame(width: MacApprovalPanelView.width)
        .fixedSize(horizontal: false, vertical: true)
        // No cancel on disappear: the presenter invalidates the approval when it takes the panel down.
    }

    /// Clicking opens macOS's Touch ID or Apple Watch dialog; while it is up, the button says what to do.
    /// When neither could be asked, the button asks again.
    private var approve: KeyringAction {
        guard approval.context != nil else { return .approve(SetupCopy.tryAgain) { approval.retry() } }
        let touchID = ownerApprovalSymbol() == "touchid"
        let title = approval.isWaiting ? (touchID ? AccessRequestCopy.useTouchID : AccessRequestCopy.useWatch)
            : (touchID ? AccessRequestCopy.clickForTouchID : AccessRequestCopy.clickForWatch)
        return .approve(title, isEnabled: !approval.isWaiting) { approval.begin() }
    }
}

extension MacApprovalPanelController {
    public func show(question title: String, lead: String, message: String, approval: OwnerApproval) {
        showPanel(MacQuestionPanelView(lead: lead, title: title, message: message, approval: approval))
    }
}
#endif
