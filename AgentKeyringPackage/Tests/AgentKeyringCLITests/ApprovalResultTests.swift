import AgentKeyringFeature
import ArgumentParser
import Foundation
import Testing
@testable import AgentKeyringCLI

@MainActor
@Suite("Honest approval results")
struct ApprovalResultTests {
    @Test("Failures have plain sentences and distinct exits; unprompted release is silent", arguments: [
        "approved", "declined", "expired", "interrupted", "not-verified",
    ])
    func result(path: String) async throws {
        try await MacOwner.$fullName.withValue("Alex Example") {
            let code: AgentBridgeErrorCode? = switch path {
            case "declined": .authorizationDenied
            case "expired": .requestExpired
            case "not-verified": .authorizationNotVerified
            case "interrupted": .authorizationInterrupted
            default: nil
            }
            let expectedExit: Int32 = switch path {
            case "declined": 2
            case "expired": 3
            case "not-verified": 6
            case "interrupted": 4
            default: 0
            }
            let expectedLine = switch path {
            case "declined": "Alex declined the request.\n"
            case "expired": "The request expired with no answer.\n"
            case "not-verified": "Touch ID or Apple Watch did not verify; retry the request.\n"
            case "interrupted": "macOS interrupted the approval prompt; retry the request.\n"
            default: ""
            }
            let output = Pipe()
            let diagnostics = Pipe()
            var actualExit: Int32 = 0
            do {
                try await CLIClient.run(.acquire(field: .password, targetURL: "https://example.com", account: nil, credentialID: nil),
                    output: output.fileHandleForWriting, diagnostics: diagnostics.fileHandleForWriting,
                    sendRequest: { request in AgentBridgeResponse(id: request.id, ok: code == nil, error: code) })
            } catch let exit as ExitCode { actualExit = exit.rawValue }
            try diagnostics.fileHandleForWriting.close()
            try output.fileHandleForWriting.close()
            let stderr = diagnostics.fileHandleForReading.readDataToEndOfFile()
            #expect(String(decoding: stderr, as: UTF8.self) == expectedLine)
            #expect(actualExit == expectedExit)
            if code != nil { #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty) }
        }
    }

    @Test("CLI socket events distinguish waiting for unlock from starting the prompt", arguments: [
        "approved", "declined", "expired", "interrupted", "not-verified",
    ], [true, false])
    func waitingResult(path: String, initiallyLocked: Bool) async throws {
        try await MacOwner.$fullName.withValue("Alex Example") {
            let code: AgentBridgeErrorCode? = switch path {
            case "declined": .authorizationDenied
            case "expired": .requestExpired
            case "not-verified": .authorizationNotVerified
            case "interrupted": .authorizationInterrupted
            default: nil
            }
            let expectedExit: Int32 = switch path {
            case "declined": 2
            case "expired": 3
            case "not-verified": 6
            case "interrupted": 4
            default: 0
            }
            let finalLine = switch path {
            case "declined": "Alex declined the request."
            case "expired": "The request expired with no answer."
            case "not-verified": "Touch ID or Apple Watch did not verify; retry the request."
            case "interrupted": "macOS interrupted the approval prompt; retry the request."
            default: "Approved at 02:43."
            }
            let bridge = AgentBridgeDirectory(rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString))
            defer { try? FileManager.default.removeItem(at: bridge.rootURL) }
            let waitingSince = try #require(Calendar.current.date(from: DateComponents(
                year: 2026, month: 10, day: 12, hour: 2, minute: 41)))
            let askedAt = initiallyLocked ? waitingSince.addingTimeInterval(60) : waitingSince
            let approvedAt = waitingSince.addingTimeInterval(120)
            let diagnostics = Pipe()
            let output = Pipe()
            var actualExit: Int32 = 0
            do {
                try await CLIClient.run(.acquire(field: .password, targetURL: "https://example.com", account: nil, credentialID: nil),
                    output: output.fileHandleForWriting, diagnostics: diagnostics.fileHandleForWriting,
                    now: { approvedAt }, sendRequest: { request in
                        let lines = CLIApprovalStatusLines(diagnostics: diagnostics.fileHandleForWriting)
                        if initiallyLocked {
                            let locked = AgentApprovalProgress(waitingSince: waitingSince, phase: .waitingForUnlock)
                            lines.receive(.progress(locked))
                            lines.receive(.stillWaiting(progress: locked))
                        }
                        let prompted = AgentApprovalProgress(waitingSince: waitingSince, askedAt: askedAt, phase: .awaitingApproval)
                        lines.receive(.progress(prompted))
                        lines.receive(.stillWaiting(progress: prompted))
                        return AgentBridgeResponse(id: request.id, ok: code == nil, error: code, approvalProgress: prompted)
                    })
            } catch let exit as ExitCode { actualExit = exit.rawValue }
            try diagnostics.fileHandleForWriting.close()
            try output.fileHandleForWriting.close()
            let stderr = diagnostics.fileHandleForReading.readDataToEndOfFile()
            let expectedStatus = initiallyLocked ? """
            Alex's Mac is locked; waiting for an unlock.
            Still waiting for Alex (waiting since 02:41).
            Asked Alex on the Mac at 02:42.
            Still waiting for Alex (asked at 02:42).

            """ : """
            Asked Alex on the Mac at 02:41.
            Still waiting for Alex (asked at 02:41).

            """
            #expect(String(decoding: stderr, as: UTF8.self) == expectedStatus + finalLine + "\n")
            #expect(actualExit == expectedExit)
            if code != nil { #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty) }
        }
    }

    @Test("Expiry while locked never claims the owner was asked")
    func lockedExpiry() async throws {
        try await MacOwner.$fullName.withValue("Alex Example") {
            let bridge = AgentBridgeDirectory(rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString))
            defer { try? FileManager.default.removeItem(at: bridge.rootURL) }
            let waitingSince = try #require(Calendar.current.date(from: DateComponents(
                year: 2026, month: 10, day: 12, hour: 2, minute: 41)))
            let diagnostics = Pipe()
            do {
                try await CLIClient.run(.acquire(field: .password, targetURL: "https://example.com", account: nil, credentialID: nil),
                    output: FileHandle.nullDevice, diagnostics: diagnostics.fileHandleForWriting,
                    sendRequest: { request in
                        let lines = CLIApprovalStatusLines(diagnostics: diagnostics.fileHandleForWriting)
                        let locked = AgentApprovalProgress(waitingSince: waitingSince, phase: .waitingForUnlock)
                        lines.receive(.progress(locked))
                        lines.receive(.stillWaiting(progress: locked))
                        throw AgentBridgeFailure(.requestExpired, "The request expired with no answer.")
                    })
                Issue.record("Expired request returned success")
            } catch let exit as ExitCode { #expect(exit.rawValue == 3) }
            try diagnostics.fileHandleForWriting.close()
            #expect(String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == """
            Alex's Mac is locked; waiting for an unlock.
            Still waiting for Alex (waiting since 02:41).
            The request expired with no answer.

            """)
        }
    }

    @Test("Transport expiry uses the same result and exit code")
    func transportExpiry() async throws {
        let diagnostics = Pipe()
        do {
            try await CLIClient.run(.acquire(field: .password, targetURL: "https://example.com", account: nil, credentialID: nil),
                output: FileHandle.nullDevice, diagnostics: diagnostics.fileHandleForWriting,
                sendRequest: { _ in throw AgentBridgeFailure(.requestExpired, "transport expiry") })
            Issue.record("Expired transport returned success")
        } catch let exit as ExitCode { #expect(exit.rawValue == 3) }
        try diagnostics.fileHandleForWriting.close()
        #expect(String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            == "The request expired with no answer.\n")
    }
}
