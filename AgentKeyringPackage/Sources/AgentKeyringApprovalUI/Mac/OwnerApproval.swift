// Written by AI on 2026.11.16 by model Claude Opus 5.5.
//
// One action approves, where Josh is already looking: Apple's Touch ID and
// Apple Watch control (or the Mac password) sits in the window that asked.
// Used for rule changes, removals and sending imported logins; the request,
// connect and join panels have their own copy of the same flow.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import Observation
import SwiftUI

/// One look at macOS's dialog, and the work it unlocks. The app gives each
/// question its own (AgentKeyringScreenBackends, `LocalOwnerAuthentication`),
/// so the screens never hold a LocalAuthentication context.
@MainActor
public protocol OwnerAuthentication: AnyObject {
    /// macOS can ask now.
    var canAsk: Bool { get }
    /// macOS's own dialog, with `reason`. True once Josh approved.
    func evaluate(reason: String) async throws -> Bool
    /// Runs the work Josh approved. Nothing it signs can open another dialog: it fails instead.
    func performApproved() async throws
    /// Closes the dialog if it is up, and ensures this approval can never be used again.
    func invalidate()
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
    /// macOS can ask: the button opens its dialog. False when it could not be asked, or once the question is over.
    public var canBegin: Bool { authentication != nil }
    public private(set) var failure: String?
    /// From the click until macOS's dialog is answered.
    public var isWaiting: Bool { task != nil }
    var timeoutDuration: Duration = .seconds(60)

    private let authenticate: @MainActor () -> any OwnerAuthentication
    private var authentication: (any OwnerAuthentication)?
    private let finish: @MainActor (Bool) -> Void
    private var task: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var attempt = UUID()
    private var finished = false

    /// - Parameters:
    ///   - authenticate: makes a new approval for each attempt; its `performApproved` runs the work.
    ///   - finish: true once the work succeeded, false when Josh cancels.
    public init(action: String, note: String? = nil, reason: String, authenticate: @escaping @MainActor () -> any OwnerAuthentication,
        finish: @escaping @MainActor (Bool) -> Void) {
        self.action = action
        self.note = note
        self.reason = reason
        self.authenticate = authenticate
        self.finish = finish
        prepare()
    }

    /// Josh clicked: macOS's own dialog asks for Touch ID or the Watch.
    public func begin() {
        guard !finished, task == nil, let authentication else { return }
        let current = attempt
        timeout = Task {
            do { try await Task.sleep(for: timeoutDuration) } catch { return }
            guard attempt == current else { return }
            stop()
            failure = "Approval timed out."
        }
        task = Task {
            do {
                let approved = try await evaluate(authentication)
                guard approved, attempt == current else { return }
                try Task.checkCancellation()
                timeout?.cancel()
                try await authentication.performApproved()
                guard attempt == current else { return }
                task = nil
                finished = true
                authentication.invalidate()
                self.authentication = nil
                finish(true)
            } catch is CancellationError {
            } catch {
                guard attempt == current else { return }
                stop()
                failure = ownerAuthenticationFailure(error, fallback: "That didn't finish. Nothing changed.")
            }
        }
    }

    private func evaluate(_ authentication: any OwnerAuthentication) async throws -> Bool {
        let box = UncheckedAuthentication(authentication)
        return try await withTaskCancellationHandler {
            try await authentication.evaluate(reason: reason)
        } onCancel: { Task { @MainActor in box.value.invalidate() } }
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
        let next = authenticate()
        guard next.canAsk else {
            next.invalidate()
            failure = AccessRequestCopy.approverUnavailable()
            return
        }
        attempt = UUID()
        authentication = next
    }

    private func stop() {
        attempt = UUID()
        task?.cancel()
        task = nil
        timeout?.cancel()
        timeout = nil
        authentication?.invalidate()
        authentication = nil
    }
}

/// An approval carried into a cancellation handler, which runs off the main actor and only hops back to it.
private struct UncheckedAuthentication: @unchecked Sendable {
    let value: any OwnerAuthentication
    init(_ value: any OwnerAuthentication) { self.value = value }
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
    /// Renders draw any approver on any Mac; nil reads macOS.
    let approverInRender: MacApproverKind?

    public init(lead: String, title: String, message: String, approval: OwnerApproval, approverInRender: MacApproverKind? = nil) {
        self.lead = lead
        self.title = title
        self.message = message
        self.approval = approval
        self.approverInRender = approverInRender
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

    /// Clicking opens macOS's dialog; while it is up, the button says what to do.
    /// When it could not be asked, the button asks again.
    private var approve: KeyringAction {
        guard approval.canBegin else { return .approve(SetupCopy.tryAgain) { approval.retry() } }
        let title = AccessRequestCopy.approveTitle(approverInRender ?? MacApprover.shared.approver, waiting: approval.isWaiting)
        return .approve(title ?? AccessRequestCopy.noApprover, isEnabled: !approval.isWaiting && title != nil) { approval.begin() }
    }
}

extension MacApprovalPanelController {
    public func show(question title: String, lead: String, message: String, approval: OwnerApproval) {
        showPanel(MacQuestionPanelView(lead: lead, title: title, message: message, approval: approval))
    }
}
#endif
