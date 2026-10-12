import AppKit
import Observation
import OSLog

private let accessibilityLogger = Logger(subsystem: "com.agentkeyring.app", category: "FillAccessibility")

@MainActor
@Observable
public final class FillAccessibilityOnboarding {
    public enum State: Sendable {
        case unknown, permissionRequired, ready, serviceUnavailable
    }

    public private(set) var state = State.unknown
    public var showInstructions: () -> Void = {}
    private let checkTrust: (Bool) async throws -> Bool
    private let openSettings: () -> Void

    public init(
        checkTrust: @escaping (Bool) async throws -> Bool = { prompt in
            try await XPCCredentialFiller().checkAccessibility(prompt: prompt)
        },
        openSettings: @escaping () -> Void = {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    ) {
        self.checkTrust = checkTrust
        self.openSettings = openSettings
    }

    public func refresh() async {
        await check(prompt: false)
    }

    public func requestPermission() async {
        await check(prompt: true)
        openSettings()
    }

    public func ensureReadyForFill() async throws {
        await refresh()
        switch state {
        case .ready: return
        case .permissionRequired:
            showInstructions()
            throw AgentBridgeFailure(.accessibilityMissing, AgentCredentialFillProcessor.accessibilityMessage)
        case .unknown, .serviceUnavailable:
            throw AgentBridgeFailure(.bridgeUnavailable, "Agent Keyring's fill service could not be reached.")
        }
    }

    private func check(prompt: Bool) async {
        do { state = try await checkTrust(prompt) ? .ready : .permissionRequired }
        catch {
            state = .serviceUnavailable
            accessibilityLogger.error("Accessibility check failed: fill service unavailable.")
        }
    }
}
