// Written by AI on 2026.11.27 by model gpt-6.2-sol.

#if os(macOS) && DEBUG
import AgentKeyringApprovalCore
import AgentKeyringEngine
import AgentKeyringProtocol
import Foundation
import LocalAuthentication

@MainActor
extension TestPeer {
    func remoteCommand(_ words: [String]) async throws -> String {
        guard words.count >= 2 else { throw PeerError("Unknown command or missing device") }
        let onPhone = words[1] == "phone"
        guard onPhone || words[1] == "mac" else { throw PeerError("Expected mac or phone") }
        switch words[0] {
        case "WAIT_REMOTE" where words.count == 2:
            return try await waitingRemote(onPhone: onPhone)
        case "APPROVE_REMOTE" where words.count == 3:
            if onPhone { try await joinedPhone().approveAccessRequest(words[2], reusingUnlock: false) }
            else { _ = try await device.approveRemote(words[2], context: LAContext(), onAuthenticated: {}) }
        case "DENY_REMOTE" where words.count >= 3:
            let reply = words.dropFirst(3).joined(separator: " ")
            if onPhone { try await joinedPhone().denyAccessRequest(words[2], reply: reply) }
            else { _ = try await device.denyRemote(words[2], reply: reply) }
        case "STOP_REMOTE" where words.count == 3:
            if onPhone { try await joinedPhone().endApprovedAccess(words[2]) }
            else { _ = try await device.stopRemote(words[2]) }
        case "WAIT_OUTCOME" where words.count == 4:
            try await waitForOutcome(words[2], state: words[3], onPhone: onPhone)
        default:
            throw PeerError("Unknown command or wrong number of arguments")
        }
        return "OK"
    }

    private func joinedPhone() throws -> PhoneKeyringEngine {
        guard let phone else { throw PeerError("Enrol the phone first") }
        return phone
    }

    private func waitingRemote(onPhone: Bool) async throws -> String {
        try await waitFor("remote ask") {
            try await deliverPushes(onPhone: onPhone)
            if onPhone {
                return try joinedPhone().snapshot.requests.first {
                    if case .waitingForYou = $0.state { return true }
                    return false
                }?.id
            }
            return device.waitingRemoteAsks.first?.id
        }
    }

    private func waitForOutcome(_ id: String, state: String, onPhone: Bool) async throws {
        _ = try await waitFor("remote outcome \(state)") { () -> Bool? in
            try await deliverPushes(onPhone: onPhone)
            if onPhone {
                guard let request = try joinedPhone().snapshot.requests.first(where: { $0.id == id }) else { return nil }
                switch request.state {
                case .unanswered where state == "unanswered": return true
                default: return request.state.isInUse && state == "approved" ? true : nil
                }
            }
            guard case let .ended(lease)? = device.remoteAsks[id]?.state else { return nil }
            return (state == "approved" && lease.state == .approved) ||
                (state == "unanswered" && lease.state == .unanswered) ? true : nil
        }
    }

    private func deliverPushes(onPhone: Bool) async throws {
        if onPhone {
            let phone = try joinedPhone()
            try await pushes.deliver(to: RecordedPushes.phoneToken) { await phone.received($0, pushDelivered: true) }
        } else {
            try await pushes.deliver(to: RecordedPushes.macToken) { device.receivedPush($0) }
        }
    }
}
#endif
