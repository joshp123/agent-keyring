import Darwin
import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Agent request lease")
struct AgentBridgeLeaseTests {
    @Test("The original request file acts as a live immutable lease")
    func requestLease() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = AgentBridgeDirectory(rootURL: root)
        let request = AgentBridgeRequest(
            action: .copy,
            targetURL: "https://example.com/login",
            field: .password
        )

        try bridge.write(request)
        #expect(bridge.requestMatches(request))

        let replacement = AgentBridgeRequest(
            id: request.id,
            createdAt: request.createdAt,
            callerPID: request.callerPID,
            action: .copy,
            targetURL: "https://example.net/login",
            field: .password
        )
        try bridge.write(replacement)
        #expect(!bridge.requestMatches(request))

        bridge.removeRequest(id: request.id)
        #expect(!bridge.requestMatches(request))
    }

    @Test("Requests expire ten minutes after creation")
    func requestExpiry() {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let request = AgentBridgeRequest(createdAt: createdAt, action: .acquire)
        #expect(request.expiresAt == createdAt.addingTimeInterval(600))
    }

    @Test("Cancelling the CLI wait leaves the app's request intact")
    func cancelledClient() async throws {
        let bridge = AgentBridgeDirectory(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: bridge.rootURL) }
        let request = AgentBridgeRequest(action: .acquire)
        let task = Task { try await AgentBridgeClient(bridge: bridge).send(request) { _ in } }
        while !bridge.requestMatches(request) { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(bridge.requestMatches(request))
    }
    @Test("The client reports waiting every thirty seconds without duplicating app status")
    @MainActor
    func waitingCadence() async throws {
        let bridge = AgentBridgeDirectory(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: bridge.rootURL) }
        let request = AgentBridgeRequest(action: .acquire)
        let clock = BridgeWaitClock(now: request.createdAt)
        var heartbeats: [Date] = []
        var statuses = 0
        let client = AgentBridgeClient(bridge: bridge, now: { clock.now }, sleep: { _ in
            clock.now = clock.now.addingTimeInterval(15)
            if clock.now.timeIntervalSince(request.createdAt) == 75 {
                try bridge.write(AgentBridgeResponse(id: request.id, ok: true))
            }
        })
        let response = try await client.send(request, onStatus: { status in
            switch status {
            case .progress: statuses += 1
            case .stillWaiting: heartbeats.append(clock.now)
            }
        }, launch: { id in
            try bridge.write(AgentApprovalProgress(waitingSince: request.createdAt, askedAt: request.createdAt, phase: .awaitingApproval), id: id)
        })
        #expect(response.ok)
        #expect(statuses == 1)
        #expect(heartbeats == [request.createdAt.addingTimeInterval(30), request.createdAt.addingTimeInterval(60)])
    }

}

@MainActor
private final class BridgeWaitClock {
    var now: Date
    init(now: Date) { self.now = now }
}
