import AgentKeyringFeature
import ArgumentParser
import Foundation
import Testing
@testable import AgentKeyringCLI

@MainActor
@Suite("Honest approval results")
struct ApprovalResultTests {
    @Test("Each approval result has a plain sentence and its own exit code", arguments: [
        "approved", "declined", "expired", "interrupted",
    ])
    func result(path: String) async throws {
        let code: AgentBridgeErrorCode? = switch path {
        case "declined": .authorizationDenied
        case "expired": .requestExpired
        case "interrupted": .authorizationInterrupted
        default: nil
        }
        let expectedExit: Int32 = switch path {
        case "declined": 2
        case "expired": 3
        case "interrupted": 4
        default: 0
        }
        let expectedLine = switch path {
        case "declined": "Josh declined the request.\n"
        case "expired": "The request expired with no answer.\n"
        case "interrupted": "macOS interrupted the approval prompt; retry the request.\n"
        default: "Approved.\n"
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

    @Test("The real CLI wait prints app status and the final result", arguments: [
        "approved", "declined", "expired", "interrupted",
    ])
    func waitingResult(path: String) async throws {
        let code: AgentBridgeErrorCode? = switch path {
        case "declined": .authorizationDenied
        case "expired": .requestExpired
        case "interrupted": .authorizationInterrupted
        default: nil
        }
        let expectedExit: Int32 = switch path {
        case "declined": 2
        case "expired": 3
        case "interrupted": 4
        default: 0
        }
        let finalLine = switch path {
        case "declined": "Josh declined the request."
        case "expired": "The request expired with no answer."
        case "interrupted": "macOS interrupted the approval prompt; retry the request."
        default: "Approved."
        }
        let bridge = AgentBridgeDirectory(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: bridge.rootURL) }
        let askedAt = try #require(Calendar.current.date(from: DateComponents(
            year: 2026, month: 10, day: 12, hour: 2, minute: 41)))
        let diagnostics = Pipe()
        let output = Pipe()
        var actualExit: Int32 = 0
        do {
            try await CLIClient.run(.acquire(field: .password, targetURL: "https://example.com", account: nil, credentialID: nil),
                output: output.fileHandleForWriting, diagnostics: diagnostics.fileHandleForWriting,
                sendRequest: { request in
                    let clock = CLIWaitClock(now: request.createdAt)
                    let client = AgentBridgeClient(bridge: bridge, now: { clock.now }, sleep: { _ in
                        clock.sleeps += 1
                        clock.now = clock.now.addingTimeInterval(30)
                        if clock.sleeps == 1 {
                            try bridge.write(AgentApprovalProgress(askedAt: askedAt, phase: .awaitingApproval), id: request.id)
                        } else if code == .requestExpired {
                            clock.now = request.expiresAt
                        } else {
                            try bridge.write(AgentBridgeResponse(id: request.id, ok: code == nil, error: code))
                        }
                    })
                    return try await CLIClient.send(request, diagnostics: diagnostics.fileHandleForWriting, client: client,
                        launch: { id in try bridge.write(AgentApprovalProgress(askedAt: askedAt, phase: .waitingForUnlock), id: id) })
                })
        } catch let exit as ExitCode { actualExit = exit.rawValue }
        try diagnostics.fileHandleForWriting.close()
        try output.fileHandleForWriting.close()
        let stderr = diagnostics.fileHandleForReading.readDataToEndOfFile()
        #expect(String(decoding: stderr, as: UTF8.self) == """
        Asked Josh on his Mac at 02:41.
        Josh's Mac is locked; waiting for him to unlock it.
        Still waiting for Josh (asked at 02:41).
        \(finalLine)

        """)
        #expect(actualExit == expectedExit)
        if code != nil { #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty) }
        try stderr.write(to: URL(fileURLWithPath: "/tmp/agent-keyring-cli-\(path)-waiting.stderr"))
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
