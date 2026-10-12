import AgentKeyringFillerSupport
import AgentKeyringTestSupport
import Foundation
import Testing
@testable import AgentKeyringFeature

@MainActor
@Suite("Fill without revealing")
struct CredentialFillTests {
    @Test("The filler requires an app bundle identifier", arguments: [nil, ""] as [String?])
    func missingBundleIdentifier(identifier: String?) throws {
        do {
            _ = try XPCCredentialFiller.serviceName(for: identifier)
            Issue.record("Missing app identity accepted")
        } catch let failure as AgentBridgeFailure {
            #expect(failure.code == .bridgeUnavailable)
            #expect(failure.message == "Agent Keyring cannot fill because the app's bundle identifier is missing.")
        }
        #expect(try XPCCredentialFiller.serviceName(for: "com.product.AgentKeyring") == "com.product.AgentKeyring.Filler")
    }

    @Test("Each invalid destination refuses without sending a value", arguments: [
        "locked", "permission", "unsupported", "unreadable", "invalid-address", "mismatch", "lookalike",
        "no-field", "plain-password", "secure-username", "secure-code", "insecure-page", "no-window",
    ], [CredentialAccessPolicy.allowAutomatically, .ask])
    func refuses(path: String, policy: CredentialAccessPolicy) async throws {
        let inspection: FillInspection = switch path {
        case "locked": fillInspection(screenLocked: true)
        case "permission": fillInspection(accessibilityTrusted: false)
        case "unsupported": fillInspection(bundleIdentifier: "org.mozilla.firefox")
        case "unreadable": fillInspection(pageAddress: nil)
        case "invalid-address": fillInspection(pageAddress: "about:blank")
        case "mismatch": fillInspection(pageAddress: "https://unrelated.invalid/login")
        case "lookalike": fillInspection(pageAddress: "https://example.com.evil.invalid/login")
        case "no-field": fillInspection(focusedRole: nil, focusedSubrole: nil, focusedElementIdentifier: nil)
        case "plain-password": fillInspection(focusedSubrole: nil)
        case "insecure-page": fillInspection(pageAddress: "http://example.com/login")
        case "no-window": fillInspection(windowIdentifier: nil)
        default: fillInspection()
        }
        let expected: AgentBridgeErrorCode = switch path {
        case "locked": .screenLocked
        case "permission": .accessibilityMissing
        case "unsupported": .unsupportedBrowser
        case "unreadable", "invalid-address": .unreadablePageAddress
        case "mismatch", "lookalike": .pageMismatch
        case "insecure-page": .insecureOrigin
        default: .wrongFocusedField
        }
        let field: AgentCredentialField = path == "secure-username" ? .username : path == "secure-code" ? .totp : .password
        let filler = FakeCredentialFiller(inspection: inspection)
        let fixture = try FillTestFixture(policy: policy, filler: filler)
        defer { fixture.cleanUp() }
        let request = try fixture.request(field: field)
        do {
            _ = try await fixture.processor.release(request: request, generation: fixture.generation, authorize: { _, _ in
                Issue.record("Refused fill prompted")
            })
            Issue.record("Refused destination filled")
        } catch let failure as AgentBridgeFailure {
            #expect(failure.code == expected)
            if expected == .pageMismatch {
                #expect(failure.message.contains(path == "lookalike" ? "example.com.evil.invalid" : "unrelated.invalid"))
                #expect(failure.message.contains("saved site example.com"))
            }
        } catch let error as CredentialResolverError {
            #expect(path == "insecure-page" && error == .insecureOrigin)
        }
        #expect(filler.typedValues.isEmpty)
        #expect(throws: CredentialTransferError.unavailable) { _ = try CredentialTransfer.read(requestID: request.id) }
    }

    @Test("All supported apps fill an exact host or subdomain", arguments: [
        "com.apple.Safari", "com.google.Chrome", "com.anthropic.claudefordesktop", "com.openai.codex",
    ], ["https://example.com/login", "https://accounts.example.com/login"])
    func supportedApps(bundleIdentifier: String, address: String) async throws {
        let filler = FakeCredentialFiller(inspection: fillInspection(bundleIdentifier: bundleIdentifier, pageAddress: address))
        let fixture = try FillTestFixture(filler: filler)
        defer { fixture.cleanUp() }
        let request = try fixture.request()
        let response = try await fixture.processor.release(request: request, generation: fixture.generation, authorize: { _, _ in })
        #expect(response.ok && response.filledField == .password)
        #expect(response.copiedField == nil && response.candidates == nil)
        #expect(filler.typedValues == [FillTestFixture.password])
        #expect(filler.expectedInspection === filler.inspection)
        #expect(filler.typingDeadline == request.expiresAt)
        #expect((filler.receivedBytes! as Data).allSatisfy { $0 == 0 })
        #expect(throws: CredentialTransferError.unavailable) { _ = try CredentialTransfer.read(requestID: request.id) }
    }

    @Test("Usernames use non-secure fields; secure roles also work for passwords", arguments: [AgentCredentialField.username, .password])
    func fieldKinds(field: AgentCredentialField) async throws {
        let filler = FakeCredentialFiller(inspection: fillInspection(
            focusedRole: field == .password ? "AXSecureTextField" : "AXTextField", focusedSubrole: nil))
        let fixture = try FillTestFixture(filler: filler)
        defer { fixture.cleanUp() }
        let response = try await fixture.processor.release(request: fixture.request(field: field),
            generation: fixture.generation, authorize: { _, _ in })
        #expect(response.ok)
        #expect(filler.typedValues == [field == .password ? FillTestFixture.password : FillTestFixture.username])
    }

    @Test("Code generation happens after approval and the final inspection")
    func freshCode() async throws {
        var now = Date(timeIntervalSince1970: 59)
        let filler = FakeCredentialFiller(inspection: fillInspection(focusedSubrole: nil))
        filler.onInspect = { if filler.inspectCount == 2 { now = Date(timeIntervalSince1970: 60) } }
        let fixture = try FillTestFixture(policy: .ask, filler: filler, now: { now })
        defer { fixture.cleanUp() }
        _ = try await fixture.processor.release(request: fixture.request(field: .totp), generation: fixture.generation,
            authorize: { approval, onPromptStarted in
                #expect(approval.fillsFocusedField)
                #expect(approval.localizedReason.contains("fill the verification code"))
                onPromptStarted()
            })
        #expect(filler.typedValues == ["37359152"])
    }

    @Test("Fill shares rules and grants with acquire", arguments: CredentialAccessPolicy.allCases)
    func policy(policy: CredentialAccessPolicy) async throws {
        let fixture = try FillTestFixture(policy: policy)
        defer { fixture.cleanUp() }
        var approvals = 0
        do {
            for _ in 0..<2 {
                _ = try await fixture.processor.release(request: fixture.request(), generation: fixture.generation,
                    authorize: { _, onPromptStarted in approvals += 1; onPromptStarted() })
            }
            #expect(policy != .block)
            #expect(fixture.filler.typedValues.count == 2)
            #expect(approvals == (policy == .ask ? 1 : 0))
        } catch let failure as AgentBridgeFailure {
            #expect(policy == .block && failure.code == .policyDenied)
            #expect(fixture.filler.typedValues.isEmpty)
        }
    }

    @Test("A destination changed during approval is validated again", arguments: ["page", "field", "address", "app"])
    func changesDuringApproval(path: String) async throws {
        let filler = FakeCredentialFiller()
        let fixture = try FillTestFixture(policy: .ask, filler: filler)
        defer { fixture.cleanUp() }
        var prompts = 0
        do {
            _ = try await fixture.processor.release(request: fixture.request(), generation: fixture.generation,
                authorize: { _, started in
                    prompts += 1; started()
                    filler.inspection = switch path {
                    case "page": fillInspection(pageAddress: "https://other.invalid")
                    case "field": fillInspection(focusedSubrole: nil)
                    case "address": fillInspection(pageAddress: nil)
                    default: fillInspection(bundleIdentifier: "org.other.app")
                    }
                })
            Issue.record("Changed destination filled")
        } catch let failure as AgentBridgeFailure {
            let expected: AgentBridgeErrorCode = switch path {
            case "page": .pageMismatch
            case "field": .wrongFocusedField
            case "address": .unreadablePageAddress
            default: .unsupportedBrowser
            }
            #expect(failure.code == expected)
        }
        #expect(prompts == 1 && filler.typedValues.isEmpty)
    }

    @Test("A fill approval never grants acquire, and an acquire approval never grants fill", arguments: [AgentBridgeAction.fill, .acquire])
    func approvalActionsStaySeparate(firstAction: AgentBridgeAction) async throws {
        let fixture = try FillTestFixture(policy: .ask)
        defer { fixture.cleanUp() }
        let otherAction: AgentBridgeAction = firstAction == .fill ? .acquire : .fill
        let loginID = fixture.generation.items[0].id
        var prompts = 0
        for action in [firstAction, otherAction, firstAction] {
            let request = AgentBridgeRequest(action: action, targetURL: "https://example.com", field: .password)
            try fixture.bridge.write(request)
            defer { CredentialTransfer.clear(requestID: request.id) }
            _ = try await fixture.processor.release(request: request, generation: fixture.generation,
                authorize: { _, started in prompts += 1; started() })
            if prompts == 1 {
                #expect(fixture.grants.contains(loginID, action: firstAction))
                #expect(!fixture.grants.contains(loginID, action: otherAction))
            }
        }
        #expect(prompts == 2)
    }

    @Test("A staged phone block reports a blocked policy rather than a decline")
    func stagedPhoneBlock() async throws {
        let fixture = try FillTestFixture(policy: .ask)
        defer { fixture.cleanUp() }
        await fixture.accessControl.refresh(from: fixture.generation)
        fixture.accessControl.stagePhoneBlock(for: fixture.generation.items[0].id)
        let request = try fixture.request()
        do {
            _ = try await fixture.processor.release(request: request, generation: fixture.generation,
                authorize: { _, _ in Issue.record("Blocked login asked for approval") })
            Issue.record("Blocked login released")
        } catch let failure as AgentBridgeFailure {
            #expect(failure.code == .policyDenied)
            #expect(failure.message == "Agent access to this credential is blocked in Agent Keyring.")
        }
        #expect(fixture.filler.inspectCount == 0)
    }

    @Test("A pending fill approval cannot satisfy a concurrent acquire approval")
    func pendingActionsStaySeparate() async throws {
        let coordinator = CredentialApprovalCoordinator(lockState: FillApprovalTestSession())
        let loginID = UUID()
        var firstPrompt: CheckedContinuation<Void, Never>?
        var prompts = 0
        let fill = Task { @MainActor in
            try await coordinator.authorize(credentialID: loginID, action: .fill,
                authorizationDeadline: Date().addingTimeInterval(60),
                approvalRequest: try ApprovalRequest(agentDisplayLabel: "Test agent", site: "example.com",
                    account: "synthetic", field: .password, action: .fill)) { started in
                prompts += 1; started()
                await withCheckedContinuation { firstPrompt = $0 }
            }
        }
        while firstPrompt == nil { await Task.yield() }
        let acquire = Task { @MainActor in
            try await coordinator.authorize(credentialID: loginID, action: .acquire,
                authorizationDeadline: Date().addingTimeInterval(60),
                approvalRequest: try ApprovalRequest(agentDisplayLabel: "Test agent", site: "example.com",
                    account: "synthetic", field: .password, action: .acquire)) { started in prompts += 1; started() }
        }
        for _ in 0..<10 { await Task.yield() }
        firstPrompt?.resume()
        try await fill.value
        try await acquire.value
        #expect(prompts == 2)
    }

    @Test("A credential ID selects the intended login among duplicate accounts")
    func duplicateAccountSelection() async throws {
        let fixture = try FillTestFixture()
        defer { fixture.cleanUp() }
        let second = MirrorItem(id: UUID(),
            sourceIdentity: MirrorSourceIdentity(exporterIdentifier: "second-fixture", accountID: Data(), itemID: Data()),
            title: "Second duplicate", origins: ["https://example.com"],
            credentials: [.password(userName: FillTestFixture.username, password: "second-synthetic-password")])
        let generation = MirrorGeneration(id: UUID(), previousGenerationID: nil, createdAt: Date(), sourceExportedAt: Date(),
            scope: .full, exporterIdentifier: "fixture", exporterDisplayName: "Fixture",
            items: fixture.generation.items + [second], skippedCredentialCount: 0)
        let request = AgentBridgeRequest(action: .fill, targetURL: "https://example.com", candidateID: second.id, field: .password)
        try fixture.bridge.write(request)
        let response = try await fixture.processor.release(request: request, generation: generation,
            authorize: { approval, started in #expect(approval.credentialTitle == second.title); started() })
        #expect(response.ok && fixture.filler.typedValues == ["second-synthetic-password"])
    }

    @Test("Missing rule signatures refuse before inspection or typing")
    func rulesNeedConfirmation() async throws {
        let fixture = try FillTestFixture()
        defer { fixture.cleanUp() }
        try Data("altered signature".utf8).write(to: fixture.bridge.rootURL.appendingPathComponent("policies.json.signature"))
        do {
            _ = try await fixture.processor.release(request: fixture.request(), generation: fixture.generation, authorize: { _, _ in })
            Issue.record("Unconfirmed rules filled")
        } catch let failure as AgentBridgeFailure { #expect(failure.code == .rulesNeedConfirmation) }
        #expect(fixture.filler.inspectCount == 0 && fixture.filler.typedValues.isEmpty)
    }

    @Test("Approval cannot bypass a rule changed to blocked")
    func blockDuringApproval() async throws {
        let fixture = try FillTestFixture(policy: .ask)
        defer { fixture.cleanUp() }
        do {
            _ = try await fixture.processor.release(request: fixture.request(), generation: fixture.generation,
                authorize: { _, _ in await fixture.accessControl.setPolicy(.block, for: [fixture.generation.items[0].id]) })
            Issue.record("Blocked login filled")
        } catch let failure as AgentBridgeFailure { #expect(failure.code == .policyDenied) }
        #expect(fixture.filler.typedValues.isEmpty)
    }

    @Test("A locked screen refuses before approval")
    func lockedAsk() async throws {
        let fixture = try FillTestFixture(policy: .ask, filler: FakeCredentialFiller(inspection: fillInspection(screenLocked: true)))
        defer { fixture.cleanUp() }
        do {
            _ = try await fixture.processor.release(request: fixture.request(), generation: fixture.generation,
                authorize: { _, _ in Issue.record("Locked fill prompted") })
            Issue.record("Locked fill succeeded")
        } catch let failure as AgentBridgeFailure { #expect(failure.code == .screenLocked) }
    }

    @Test("Request and policy checks remain current across inspection", arguments: ["expired", "blocked", "rules"])
    func changesDuringInspection(path: String) async throws {
        var now = Date()
        let filler = FakeCredentialFiller()
        let fixture = try FillTestFixture(filler: filler, now: { now })
        defer { fixture.cleanUp() }
        let request = try fixture.request()
        filler.onInspect = {
            guard filler.inspectCount == 2 else { return }
            switch path {
            case "expired": now = request.expiresAt
            case "blocked": await fixture.accessControl.setPolicy(.block, for: [fixture.generation.items[0].id])
            default:
                try? Data("altered signature".utf8).write(to: fixture.bridge.rootURL.appendingPathComponent("policies.json.signature"))
            }
        }
        do {
            _ = try await fixture.processor.release(request: request, generation: fixture.generation, authorize: { _, _ in })
            Issue.record("Stale authorization filled")
        } catch let failure as AgentBridgeFailure {
            let expected: AgentBridgeErrorCode = path == "expired" ? .requestExpired : path == "blocked" ? .policyDenied : .rulesNeedConfirmation
            #expect(failure.code == expected)
        }
        #expect(filler.typedValues.isEmpty)
    }

    @Test("Helper refusals stay refusals", arguments: [FillTypingResult.accessibilityMissing, .screenLocked, .targetChanged, .failed, .requestExpired])
    func helperRefusal(result: FillTypingResult) async throws {
        let fixture = try FillTestFixture()
        defer { fixture.cleanUp() }
        fixture.filler.result = result
        let expected: AgentBridgeErrorCode = switch result {
        case .accessibilityMissing: .accessibilityMissing
        case .screenLocked: .screenLocked
        case .targetChanged: .fillTargetChanged
        case .requestExpired: .requestExpired
        default: .internalError
        }
        do {
            _ = try await fixture.processor.release(request: fixture.request(), generation: fixture.generation, authorize: { _, _ in })
            Issue.record("Helper refusal reported success")
        } catch let failure as AgentBridgeFailure { #expect(failure.code == expected) }
    }
}

private struct FillApprovalTestSession: CredentialSessionLockState { var isLocked: Bool { false } }
