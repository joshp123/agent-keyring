import Darwin
import Foundation
import Testing
@testable import AgentKeyringFeature

@MainActor
@Suite("Authenticated Unix socket requests")
struct AgentSocketTests {
    @Test("Requests expire ten minutes after creation")
    func requestExpiry() {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        #expect(AgentBridgeRequest(createdAt: createdAt, action: .acquire).expiresAt == createdAt.addingTimeInterval(600))
    }

    @Test("Socket round trip carries progress and results; forged PID and label have no authority")
    func roundTrip() async throws {
        let bridge = temporaryBridge()
        defer { try? FileManager.default.removeItem(at: bridge.rootURL) }
        let request = AgentBridgeRequest(callerPID: 1, agentDisplayLabel: "Claude Code, verified (Anthropic)", action: .status)
        let progress = AgentApprovalProgress(waitingSince: request.createdAt, askedAt: request.createdAt, phase: .awaitingApproval)
        var receivedRequester: AgentRequester?
        let server = try AgentBridgeServer(bridge: bridge) { received, peer, publish in
            #expect(received == request)
            #expect(peer.processIdentifier == getpid())
            #expect(peer.processIdentifier != received.callerPID)
            #expect(peer.auditToken.count == MemoryLayout<audit_token_t>.size)
            let requester = AgentRequester.from(peer: peer)
            receivedRequester = requester
            #expect(requester.processIdentifier == peer.processIdentifier)
            #expect(requester.verifiedIdentity == nil)
            #expect(requester.displayLabel != received.agentDisplayLabel)
            #expect(!requester.context.machineName.isEmpty)
            #expect(requester.context.workingDirectory == FileManager.default.currentDirectoryPath)
            publish(progress)
            return AgentBridgeResponse(id: received.id, ok: true, message: "Socket receipt", approvalProgress: progress)
        }
        var statuses: [AgentApprovalProgress] = []
        let result = try await AgentBridgeClient(bridge: bridge).send(request, onStatus: {
            if case let .progress(value) = $0 { statuses.append(value) }
        }) { _ in Issue.record("Existing listener launched the app") }
        #expect(result.ok && result.message == "Socket receipt" && result.approvalProgress == progress)
        #expect(statuses == [progress])
        #expect(receivedRequester != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: bridge.rootURL.path)
        #expect(files == ["agent.sock"])
        let permissions = try FileManager.default.attributesOfItem(atPath: bridge.socketURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        withExtendedLifetime(server) { }
    }

    @Test("An absent socket launches the app, then connects")
    func launchesListener() async throws {
        let bridge = temporaryBridge()
        defer { try? FileManager.default.removeItem(at: bridge.rootURL) }
        let holder = SocketServerHolder()
        let request = AgentBridgeRequest(action: .status)
        let response = try await AgentBridgeClient(bridge: bridge).send(request) { _ in
            await MainActor.run {
                do {
                    holder.server = try AgentBridgeServer(bridge: bridge) { request, _, _ in
                        AgentBridgeResponse(id: request.id, ok: true)
                    }
                } catch { Issue.record(error) }
            }
        }
        #expect(response.ok)
        #expect(holder.server != nil)
    }

    @Test("Stopping the client wait leaves the app's approval running")
    func cancelledClient() async throws {
        let bridge = temporaryBridge()
        defer { try? FileManager.default.removeItem(at: bridge.rootURL) }
        var finish: CheckedContinuation<Void, Never>?
        var completed = false
        let server = try AgentBridgeServer(bridge: bridge) { request, _, _ in
            await withCheckedContinuation { finish = $0 }
            completed = true
            return AgentBridgeResponse(id: request.id, ok: true)
        }
        let client = Task { try await AgentBridgeClient(bridge: bridge).send(AgentBridgeRequest(action: .status)) { _ in } }
        while finish == nil { await Task.yield() }
        client.cancel()
        await #expect(throws: CancellationError.self) { try await client.value }
        #expect(!completed)
        finish?.resume()
        while !completed { await Task.yield() }
        withExtendedLifetime(server) { }
    }

    @Test("A short browser deadline returns approval pending while the app continues")
    func pendingDeadline() async throws {
        let bridge = temporaryBridge()
        defer { try? FileManager.default.removeItem(at: bridge.rootURL) }
        var finish: CheckedContinuation<Void, Never>?
        let progress = AgentApprovalProgress(waitingSince: Date(), askedAt: Date(), phase: .awaitingApproval)
        let server = try AgentBridgeServer(bridge: bridge) { request, _, publish in
            publish(progress)
            await withCheckedContinuation { finish = $0 }
            return AgentBridgeResponse(id: request.id, ok: true)
        }
        let response = try await AgentBridgeClient(bridge: bridge).send(AgentBridgeRequest(action: .acquire),
            waitUntil: Date().addingTimeInterval(0.1)) { _ in }
        #expect(response.error == .approvalPending && response.approvalProgress == progress)
        finish?.resume()
        withExtendedLifetime(server) { }
    }

    @Test("Waiting emits one status and a reminder after thirty seconds")
    func waitingCadence() async throws {
        let bridge = temporaryBridge()
        defer { try? FileManager.default.removeItem(at: bridge.rootURL) }
        let start = ContinuousClock.now
        var updates = 0
        var reminders: [Duration] = []
        let server = try AgentBridgeServer(bridge: bridge) { request, _, publish in
            let progress = AgentApprovalProgress(waitingSince: Date(), phase: .awaitingApproval)
            publish(progress)
            publish(progress)
            try await Task.sleep(for: .seconds(31))
            return AgentBridgeResponse(id: request.id, ok: true)
        }
        _ = try await AgentBridgeClient(bridge: bridge).send(AgentBridgeRequest(action: .status), onStatus: { status in
            switch status {
            case .progress: updates += 1
            case .stillWaiting: reminders.append(start.duration(to: .now))
            }
        }) { _ in }
        #expect(updates == 1 && reminders.count == 1)
        #expect(reminders.first.map { $0 >= .seconds(30) && $0 < .seconds(35) } == true)
        withExtendedLifetime(server) { }
    }

    private func temporaryBridge() -> AgentBridgeDirectory {
        AgentBridgeDirectory(rootURL: URL(fileURLWithPath: "/tmp/ak-\(UUID().uuidString)"))
    }
}

@MainActor
private final class SocketServerHolder { var server: AgentBridgeServer? }
