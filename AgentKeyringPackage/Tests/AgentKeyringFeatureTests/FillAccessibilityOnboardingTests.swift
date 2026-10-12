import AgentKeyringTestSupport
import Foundation
import Testing
@testable import AgentKeyringFeature

@MainActor
@Suite("Fill Accessibility onboarding")
struct FillAccessibilityOnboardingTests {
    @Test("Launch checks trust without prompting or opening Settings", arguments: [false, true])
    func launchCheck(trusted: Bool) async {
        var prompts: [Bool] = []
        var settingsOpened = false
        let onboarding = FillAccessibilityOnboarding(checkTrust: { prompt in
            prompts.append(prompt)
            return trusted
        }, openSettings: { settingsOpened = true })
        #expect(onboarding.state == .unknown)
        await onboarding.refresh()
        #expect(onboarding.state == (trusted ? .ready : .permissionRequired))
        #expect(prompts == [false] && !settingsOpened)
    }

    @Test("The button prompts through the helper before opening Accessibility settings")
    func permissionButton() async throws {
        var actions: [String] = []
        var trusted = false
        let onboarding = FillAccessibilityOnboarding(checkTrust: { prompt in
            actions.append(prompt ? "prompt-helper" : "check-helper")
            return trusted
        }, openSettings: { actions.append("open-settings") })
        await onboarding.refresh()
        await onboarding.requestPermission()
        #expect(actions == ["check-helper", "prompt-helper", "open-settings"])
        #expect(onboarding.state == .permissionRequired)
        trusted = true
        await onboarding.refresh()
        #expect(onboarding.state == .ready)
        try await onboarding.ensureReadyForFill()
        #expect(actions.suffix(2) == ["check-helper", "check-helper"])
    }

    @Test("A fill rechecks permission and shows the step if permission was removed")
    func permissionRemoved() async throws {
        var trusted = true
        var instructionsShown = 0
        let onboarding = FillAccessibilityOnboarding(checkTrust: { prompt in
            #expect(!prompt)
            return trusted
        }, openSettings: { Issue.record("Fill opened Settings without the button") })
        onboarding.showInstructions = { instructionsShown += 1 }
        await onboarding.refresh()
        #expect(onboarding.state == .ready)
        trusted = false
        do {
            try await onboarding.ensureReadyForFill()
            Issue.record("Fill accepted missing permission")
        } catch let failure as AgentBridgeFailure {
            #expect(failure.code == .accessibilityMissing)
            #expect(failure.message == "Open Agent Keyring and click ‘Allow Agent Keyring to fill sign-in forms’.")
        }
        #expect(onboarding.state == .permissionRequired && instructionsShown == 1)
    }

    @Test("An unavailable helper is not mistaken for missing permission")
    func helperUnavailable() async {
        let onboarding = FillAccessibilityOnboarding(checkTrust: { _ in
            throw AgentBridgeFailure(.bridgeUnavailable, "Unavailable")
        }, openSettings: {})
        onboarding.showInstructions = { Issue.record("Unavailable service requested permission") }
        await onboarding.refresh()
        #expect(onboarding.state == .serviceUnavailable)
        do {
            try await onboarding.ensureReadyForFill()
            Issue.record("Fill accepted an unavailable helper")
        } catch let failure as AgentBridgeFailure {
            #expect(failure.code == .bridgeUnavailable)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("The app's first fill checks Accessibility before opening the vault or approving")
    func firstFillRequest() async throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = AgentBridgeDirectory(rootURL: directory.appendingPathComponent("bridge"))
        var checks = 0
        var instructionsShown = false
        let onboarding = FillAccessibilityOnboarding(checkTrust: { prompt in
            #expect(!prompt)
            checks += 1
            return false
        }, openSettings: { Issue.record("Fill opened Settings without the button") })
        onboarding.showInstructions = { instructionsShown = true }
        let model = MirrorAppModel(store: EncryptedSnapshotStore(directoryURL: directory.appendingPathComponent("vault"),
            keyProvider: StaticVaultKeyProvider(keyData: Data(repeating: 0x42, count: 32))),
            bridge: bridge, fillAccessibility: onboarding)
        let request = AgentBridgeRequest(action: .fill, targetURL: "https://example.com", field: .password)

        let response = try await sendTestAgentRequest(request, model: model, bridge: bridge)
        #expect(!response.ok && response.error == .accessibilityMissing)
        #expect(checks == 1 && instructionsShown && onboarding.state == .permissionRequired)
    }
}
