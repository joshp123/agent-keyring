// Written by AI on 2026.11.27 by model claude opus 5.5, from OwnerApproval's
// own LocalAuthentication code.
//
// macOS's own dialog for a question beside Josh's window: Touch ID or the
// Watch, or the Mac password, as this Mac's keys were made. A new context for
// each attempt; once approved it allows no further dialog, so nothing the
// approved work signs can ask him again: it fails instead.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import LocalAuthentication

@MainActor
public final class LocalOwnerAuthentication: OwnerAuthentication {
    private let context = LAContext()
    private let perform: @MainActor (LAContext) async throws -> Void

    /// - Parameter perform: runs after Josh approved, with the evaluated context.
    public init(perform: @escaping @MainActor (LAContext) async throws -> Void) {
        self.perform = perform
    }

    public var canAsk: Bool { AgentKeyringApprovalCore.canAsk(context, MacApprovalMode.current.policy) }

    public func evaluate(reason: String) async throws -> Bool {
        MacApprovalMode.current.prepareAuthenticationContext(context)
        return try await context.evaluatePolicy(MacApprovalMode.current.policy, localizedReason: reason)
    }

    public func performApproved() async throws {
        context.interactionNotAllowed = true
        try await perform(context)
    }

    public func invalidate() { context.invalidate() }
}
#endif
