// Written by AI on 2026.11.01 by model gpt-6.1-sol.
import AgentKeyringFeature
@testable import AgentKeyringPhoneApprover
import AgentKeyringProtocol
import AgentKeyringRelaySupport
import Foundation
import LocalAuthentication
import Network
import Testing

@MainActor private struct UnusedKeys: PhoneApproverKeys {
    func signingPublicKey() throws -> Data { throw CancellationError() }
    func encryptionPublicKey() throws -> Data { throw CancellationError() }
    func openCopy(encapsulatedKey: Data, ciphertext: Data, associatedData: Data, context: LAContext) throws -> Data { throw CancellationError() }
    func authorize(_ context: LAContext, reason: String) async throws { throw CancellationError() }
    func sign(_ bytes: Data, context: LAContext) throws -> Data { throw CancellationError() }
}

@Test @MainActor func reopeningPhonePrunesCompletedHistoryButKeepsLostAnswersAndReceipts() throws {
    let now = PhoneRelayApprover.now
    var state = PhoneApproverState()
    let login = PhoneRequestLogin(Agentkeyring_V1_Login())
    func request(_ id: String, ended: Int64, answer: Bool = false, acknowledged: Bool = true) throws -> PhoneSavedRequest {
        var lease = Agentkeyring_V1_Lease()
        lease.leaseID = id; lease.state = .released; lease.endedAtUnixSeconds = ended
        return PhoneSavedRequest(record: Data(), lease: try lease.serializedData(), metadata: login,
                                 machine: Data(), sourceMacKeyID: "dummy", isLocal: false,
                                 decision: answer ? Data([1]) : nil, acknowledged: acknowledged)
    }
    for index in 0..<1000 {
        let id = String(index)
        state.requests[id] = try request(id, ended: now - 8 * 86400)
        state.remoteLeases[id] = state.requests[id]!.lease
    }
    state.requests["recent"] = try request("recent", ended: now - 86400)
    state.requests["lost-answer"] = try request("lost-answer", ended: now - 8 * 86400, answer: true, acknowledged: false)
    state.remoteLeases["lost-answer"] = state.requests["lost-answer"]!.lease
    var receipt = Agentkeyring_V1_RelayWireRequest(); receipt.publishUpdateReceipt.receipt = Data([7])
    state.outbox = [try receipt.serializedData()]
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Test-owned dummy checkpoints only; use the user's Trash convention.
    defer { _ = try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
    let checkpoint = directory.appending(path: "phone-answers-v3.plist")
    try PropertyListEncoder().encode(state).write(to: checkpoint)
    let phone = PhoneRelayApprover(directory: directory, keys: UnusedKeys(), identity: { throw CancellationError() }, replaceIdentity: {})
    try phone.load()
    #expect(Set(phone.state.requests.keys) == ["recent", "lost-answer"])
    #expect(Set(phone.state.remoteLeases.keys) == ["lost-answer"])
    #expect(phone.state.outbox == state.outbox)
    let saved = try PropertyListDecoder().decode(PhoneApproverState.self, from: Data(contentsOf: checkpoint))
    #expect(saved.requests.count == 2)
    #expect(try saved.nextHistoryDeadline(now: now) == now + 6 * 86400)
    var completed = saved
    completed.requests["lost-answer"]!.acknowledged = true
    try completed.pruneHistory(now: now + 7 * 86400)
    #expect(completed.requests.isEmpty && completed.remoteLeases.isEmpty)
    #expect(completed.outbox == state.outbox)
    #expect(try completed.nextHistoryDeadline(now: now + 7 * 86400) == nil)
    phone.state = completed
    phone.state.outbox = []
    phone.state.keySet = Data([1])
    phone.state.endpoint = try RelayEndpoint(host: "relay.example", port: 443)
    phone.start()
    #expect(phone.retryTask == nil && phone.historyTask == nil)
    phone.stop()
    phone.state.outbox = state.outbox
    phone.start()
    #expect(phone.retryTask != nil) // A lost receipt has real retry work.
    phone.stop()
}

@Test func macAndPhoneUseTheSameResolvedAddressPolicy() throws {
    let endpoint = try RelayEndpoint(host: "relay.example", port: 443)
    func permits(_ address: String) -> Bool {
        endpoint.permitsResolvedEndpoint(.hostPort(host: NWEndpoint.Host(address), port: 443))
    }
    #expect(permits("100.100.1.2"))
    #expect(permits("::ffff:100.100.1.2"))
    #expect(endpoint.permitsResolvedEndpoint(.hostPort(host: .ipv6(IPv6Address("::ffff:100.100.1.2")!), port: 443)))
    #expect(permits("fd7a:115c:a1e0::1"))
    #expect(!permits("::ffff:192.168.1.2"))
    #expect(!permits("::ffff:127.0.0.1"))
    let proof = try RelayEndpoint(host: "localhost", port: 443, allowsLoopbackForProof: true)
    #expect(proof.permitsResolvedEndpoint(.hostPort(host: "::ffff:127.0.0.1", port: 443)))
}
