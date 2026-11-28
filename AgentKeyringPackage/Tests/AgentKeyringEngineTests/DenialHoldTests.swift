// Written by AI on 2026.11.20 by model claude opus 5.5.
// Josh denies an agent on this Mac: it may ask again a minute later, five
// minutes after a second denial in a row, fifteen after more; an hour with
// no denial starts again at a minute. It reads when, and his words.

@testable import AgentKeyringEngine
import AgentKeyringProtocol
import Foundation
import Testing

struct DenialHoldTests {
    typealias Hold = CredentialLeaseStore.Suppression

    @Test("Each denial in a row holds the agent off longer; an hour later it starts again")
    func growing() {
        let first = Hold.after(nil, reply: "Use the work account.", now: 1000)
        #expect(first.until == 1060)
        let second = Hold.after(first, reply: "", now: 1100)
        #expect(second.until == 1400)
        let third = Hold.after(second, reply: "", now: 1500)
        #expect(third.until == 2400)
        #expect(Hold.after(third, reply: "", now: 2400 + 3601).until == 2400 + 3601 + 60)
    }

    @MainActor @Test("The agent is told when it may ask again, and his words exactly")
    func told() {
        let line = CredentialLeaseStore.heldOff(1060, reply: "Use the work account.")
        #expect(line.contains(Date(timeIntervalSince1970: 1060).formatted(date: .omitted, time: .standard)))
        #expect(line.contains("\"Use the work account.\""))
    }
}

/// An agent asks for a password that has no website, such as a server's: the
/// request waits for Josh. It used to end at once, and the agent was told
/// Josh had stopped it.
@MainActor @Test func aPasswordWithNoWebsiteWaitsForJosh() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "LeaseTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CredentialLeaseStore(persistence: LeasePersistence(directory: directory))
    let server = CredentialCandidate(id: UUID(), title: "Home server", username: "admin", origins: [], availableFields: [.username, .password])
    var asking = Agentkeyring_V2_RequestLeaseRequest()
    asking.loginID = server.id.uuidString
    asking.requestID = UUID().uuidString
    asking.taskRef = "backup"
    asking.reason = "You asked me to check the backups."
    let lease = try store.recordLeaseRequest(asking, login: server, rule: .ask)
    try store.reconcile(logins: [server], rules: [:])
    #expect(try store.get(lease.requestID).state == .waiting)
}
