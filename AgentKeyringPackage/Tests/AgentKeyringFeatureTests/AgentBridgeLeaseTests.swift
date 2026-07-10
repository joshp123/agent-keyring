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

    @Test("The bridge can detect whether the requesting process still exists")
    func callerLiveness() {
        let bridge = AgentBridgeDirectory()

        #expect(bridge.callerIsAlive(pid: getpid()))
        #expect(!bridge.callerIsAlive(pid: -1))
    }
}
