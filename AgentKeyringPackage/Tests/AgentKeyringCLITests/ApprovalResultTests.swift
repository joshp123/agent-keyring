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
        case "declined": "Josh declined the request.\n"
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
        try stderr.write(to: URL(fileURLWithPath: "/tmp/agent-keyring-cli-\(path).stderr"))
    }

    @Test("The real CLI wait distinguishes waiting for unlock from starting the prompt", arguments: [
        "approved", "declined", "expired", "interrupted", "not-verified",
    ], [true, false])
    func waitingResult(path: String, initiallyLocked: Bool) async throws {
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
        case "declined": "Josh declined the request."
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
                    let clock = CLIWaitClock(now: request.createdAt)
                    let client = AgentBridgeClient(bridge: bridge, now: { clock.now }, sleep: { _ in
                        clock.sleeps += 1
                        clock.now = clock.now.addingTimeInterval(30)
                        if initiallyLocked, clock.sleeps == 2 {
                            try bridge.write(AgentApprovalProgress(waitingSince: waitingSince,
                                askedAt: askedAt, phase: .awaitingApproval), id: request.id)
                        } else if clock.sleeps == (initiallyLocked ? 3 : 2), code == .requestExpired {
                            clock.now = request.expiresAt
                        } else if clock.sleeps == (initiallyLocked ? 3 : 2) {
                            try bridge.write(AgentBridgeResponse(id: request.id, ok: code == nil, error: code,
                                approvalProgress: try bridge.readProgress(id: request.id)))
                        }
                    })
                    return try await CLIClient.send(request, diagnostics: diagnostics.fileHandleForWriting, client: client,
                        launch: { id in
                            try bridge.write(AgentApprovalProgress(waitingSince: waitingSince,
                                askedAt: initiallyLocked ? nil : askedAt,
                                phase: initiallyLocked ? .waitingForUnlock : .awaitingApproval), id: id)
                        })
                })
        } catch let exit as ExitCode { actualExit = exit.rawValue }
        try diagnostics.fileHandleForWriting.close()
        try output.fileHandleForWriting.close()
        let stderr = diagnostics.fileHandleForReading.readDataToEndOfFile()
        let expectedStatus = initiallyLocked ? """
        Josh's Mac is locked; waiting for him to unlock it.
        Still waiting for Josh (waiting since 02:41).
        Asked Josh on his Mac at 02:42.
        Still waiting for Josh (asked at 02:42).

        """ : """
        Asked Josh on his Mac at 02:41.
        Still waiting for Josh (asked at 02:41).

        """
        #expect(String(decoding: stderr, as: UTF8.self) == expectedStatus + finalLine + "\n")
        #expect(actualExit == expectedExit)
        if code != nil { #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty) }
        let lockPath = initiallyLocked ? "locked" : "unlocked"
        try stderr.write(to: URL(fileURLWithPath: "/tmp/agent-keyring-cli-\(path)-\(lockPath).stderr"))
    }

    @Test("Expiry while locked never claims Josh was asked")
    func lockedExpiry() async throws {
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
                    let clock = CLIWaitClock(now: request.createdAt)
                    let client = AgentBridgeClient(bridge: bridge, now: { clock.now }, sleep: { _ in
                        clock.sleeps += 1
                        clock.now = clock.sleeps == 1 ? clock.now.addingTimeInterval(30) : request.expiresAt
                    })
                    return try await CLIClient.send(request, diagnostics: diagnostics.fileHandleForWriting, client: client,
                        launch: { id in
                            try bridge.write(AgentApprovalProgress(waitingSince: waitingSince, phase: .waitingForUnlock), id: id)
                        })
                })
            Issue.record("Expired request returned success")
        } catch let exit as ExitCode { #expect(exit.rawValue == 3) }
        try diagnostics.fileHandleForWriting.close()
        #expect(String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == """
        Josh's Mac is locked; waiting for him to unlock it.
        Still waiting for Josh (waiting since 02:41).
        The request expired with no answer.

        """)
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

@MainActor
private final class CLIWaitClock {
    var now: Date
    var sleeps = 0
    init(now: Date) { self.now = now }
}
