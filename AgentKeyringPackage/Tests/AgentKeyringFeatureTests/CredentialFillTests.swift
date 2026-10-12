import AgentKeyringFillerSupport
import AgentKeyringTestSupport
import Foundation
import Testing
@testable import AgentKeyringFeature

@MainActor
@Suite("Fill without revealing")
struct CredentialFillTests {
    @Test("Each invalid destination refuses without sending a value", arguments: [
        "locked", "permission", "unsupported", "unreadable", "invalid-address", "mismatch", "lookalike",
        "no-field", "plain-password", "secure-username", "secure-code", "insecure-page", "no-window",
    ])
    func refuses(path: String) async throws {
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
        let fixture = try FillTestFixture(filler: filler)
        defer { fixture.cleanUp() }
        let request = try fixture.request(field: field)
        do {
            _ = try await fixture.processor.release(request: request, generation: fixture.generation, authorize: { _, _ in
                Issue.record("Automatic rule prompted")
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

    @Test("Helper refusals stay refusals", arguments: [FillTypingResult.accessibilityMissing, .screenLocked, .targetChanged, .failed])
    func helperRefusal(result: FillTypingResult) async throws {
        let fixture = try FillTestFixture()
        defer { fixture.cleanUp() }
        fixture.filler.result = result
        let expected: AgentBridgeErrorCode = switch result {
        case .accessibilityMissing: .accessibilityMissing
        case .screenLocked: .screenLocked
        case .targetChanged: .fillTargetChanged
        default: .internalError
        }
        do {
            _ = try await fixture.processor.release(request: fixture.request(), generation: fixture.generation, authorize: { _, _ in })
            Issue.record("Helper refusal reported success")
        } catch let failure as AgentBridgeFailure { #expect(failure.code == expected) }
    }
}
