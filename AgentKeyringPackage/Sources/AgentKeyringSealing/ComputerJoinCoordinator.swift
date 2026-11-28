// Written by AI on 2026.11.23 by model claude opus 5.5; read, then deleted, on 2026.11.24.
//
// The inviting side of joining with a code, shared by the Mac and the iPhone:
// pick up the computer's JoinRequest from the code's request box, check it
// proves the code, and later put the JoinStatus in the code's response box.
// What happens in between (Touch ID or Face ID, the new Members) is the
// inviting device's own.

import AgentKeyringProtocol
import CryptoKit
import Foundation

public enum ComputerJoinCoordinator {
    /// The computer's join from the code's request box, read at `RelayBoxProtocol.pollInterval`'s pace until `expires` or
    /// until `stillWanted` says the code was withdrawn, then deleted. Nil if none came, or if what came
    /// is not a computer's join that proves this code.
    public static func takeComputerJoinRequest(_ keys: ComputerJoinCodeKeys, at relay: RelayBoxClient, until expires: Date,
                                   stillWanted: @escaping @MainActor () -> Bool) async -> Agentkeyring_V2_JoinRequest? {
        var raw: Data?
        let started = Date()
        while raw == nil, Date() < expires, await stillWanted(), !Task.isCancelled {
            if let picked = try? await relay.fetchRelayBox(box: keys.requestBox, key: keys.requestKey) {
                raw = picked.message
                try? await relay.acknowledgeRelayBox(picked)
            } else {
                try? await Task.sleep(for: RelayBoxProtocol.pollInterval(waited: Date().timeIntervalSince(started)))
            }
        }
        guard let raw, await stillWanted(), let request = try? Agentkeyring_V2_JoinRequest(serializedBytes: raw),
              let machine = joiningComputer(request), CredentialSealing.joinProof(secret: keys.proof, joining: request) == request.proof,
              machine.machineID == CredentialSealing.keyID(machine.tlsPublicKey),
              (try? P256.KeyAgreement.PublicKey(x963Representation: machine.receivingPublicKey)) != nil else { return nil }
        return request
    }

    /// The computer a join names, if it names one.
    public static func joiningComputer(_ request: Agentkeyring_V2_JoinRequest) -> Agentkeyring_V2_Machine? {
        if case let .machine(machine)? = request.joining { return machine }
        return nil
    }

    /// A refusal the computer's agent can check came from whoever holds the code.
    public static func refusedJoinStatus(_ request: Agentkeyring_V2_JoinRequest, _ keys: ComputerJoinCodeKeys, reply: String) -> Agentkeyring_V2_JoinStatus {
        var status = Agentkeyring_V2_JoinStatus()
        status.state = .refused
        status.challenge = request.challenge
        let id = joiningComputer(request)?.machineID ?? ""
        status.refusal.joinerID = id
        status.refusal.reply = reply
        status.refusal.replyProof = CredentialSealing.refusalReplyProof(secret: keys.proof, machineID: id, reply: reply)
        return status
    }

    /// Puts the answer in the code's response box, with the request's challenge.
    public static func sendJoinStatus(_ status: Agentkeyring_V2_JoinStatus, to request: Agentkeyring_V2_JoinRequest,
                              _ keys: ComputerJoinCodeKeys, at relay: RelayBoxClient) async throws {
        var status = status
        status.challenge = request.challenge
        try await relay.putRelayBox(status.serializedData(), box: keys.responseBox, key: keys.responseKey)
    }
}
