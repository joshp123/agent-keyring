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

/// The control in place: "Touch ID or Apple Watch to change this rule", with
/// Cancel, or what went wrong and Try again.
public struct OwnerApprovalBar: View {
    let approval: OwnerApproval
    let cancelTitle: String

    public init(approval: OwnerApproval, cancelTitle: String = "Cancel") {
        self.approval = approval
        self.cancelTitle = cancelTitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note = approval.note {
                Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            controls
        }
        .padding(12)
        .background(KeyringColour.signal.opacity(0.08), in: .rect(cornerRadius: 10))
        .onDisappear { approval.cancel() }
    }

    // One above the other: side by side, the green button was cut off at "Click here, then touch the sen…".
    @ViewBuilder private var controls: some View {
        if approval.context != nil {
            VStack(alignment: .leading, spacing: KeyringSpace.s2) {
                TouchIDButton(action: approval.action, isWaiting: approval.isWaiting) { approval.begin() }
                cancelButton
            }
        } else {
            // Without the control, say what Try again would approve.
            Text(SetupCopy.touchIDTo(approval.action)).font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(approval.failure ?? "")
                .font(.callout)
                .foregroundStyle(KeyringColour.denyText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: KeyringSpace.s2) {
                KeyringButton(.approve(SetupCopy.tryAgain) { approval.retry() })
                cancelButton
            }
        }
    }

    private var cancelButton: some View {
        KeyringButton(.plain(cancelTitle) { approval.cancel() })
    }
}

/// A question that needs Josh's approval and nothing else, in the floating
/// panel beside his window: connecting the Mac mini, sending imported logins.
public struct MacQuestionPanelView: View {
    let title: String
    let message: String
    let approval: OwnerApproval

    public init(title: String, message: String, approval: OwnerApproval) {
        self.title = title
        self.message = message
        self.approval = approval
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "key.horizontal.fill").foregroundStyle(KeyringColour.signal)
                Text(SetupCopy.appName).font(.subheadline.weight(.semibold))
            }
            KeyringText(title, as: .heading)
            KeyringText(message, as: .meta)
            OwnerApprovalBar(approval: approval, cancelTitle: SetupCopy.notNow)
        }
        .padding(18)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension MacApprovalPanelController {
    public func show(question title: String, message: String, approval: OwnerApproval) {
        showPanel(MacQuestionPanelView(title: title, message: message, approval: approval))
    }
}
#endif
