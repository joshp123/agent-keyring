import AgentKeyringProtocol
import AgentKeyringRelaySupport
import Foundation
import LocalAuthentication

extension PhoneRelayApprover {
    func queueDirectDecision(_ id: String, record: Agentkeyring_V1_RequestRecord,
                             machine: Agentkeyring_V1_EnrolledMachine, contents: Agentkeyring_V1_AutomaticLoginContents?,
                             reply: String, context: LAContext?) throws {
        let approving = contents != nil
        var statement = Agentkeyring_V1_DecisionStatement()
        statement.domain = "agentkeyring.decision.v1"
        statement.requestDigest = RelayCrypto.digest("agentkeyring.request.v1", state.requests[id]!.record)
        statement.choice = approving ? .approve : .deny
        statement.approvedAtUnixSeconds = Self.now
        statement.notAfterUnixSeconds = approving ? statement.approvedAtUnixSeconds + 1800 : 0
        statement.recipientID = record.recipientID; statement.receiverKeyID = machine.receiverKeyID
        statement.leaseID = record.leaseID; statement.replySha256 = RelayCrypto.hash(Data(reply.utf8))
        statement.authority = !approving && reply.isEmpty ? .approverConnection : .human
        var decision = Agentkeyring_V1_SignedDecision()
        decision.approverKeyID = RelayCrypto.keyID(try keys.signingPublicKey()); decision.reply = reply
        if let contents {
            let bundle = try RelayLoginBundle.contents(copy: contents, leaseID: record.leaseID,
                approvedAt: statement.approvedAtUnixSeconds, notAfter: statement.notAfterUnixSeconds)
            decision.bundle = try RelayCrypto.seal(bundle, receiverKey: machine.receiverPublicKey, requestDigest: statement.requestDigest)
            statement.bundleCiphertextSha256 = RelayCrypto.hash(decision.bundle.ciphertext)
        }
        decision.statement = try statement.serializedData()
        if statement.authority != .approverConnection {
            guard let context else { throw RelayFailure(.permissionDenied, "Face ID is required.") }
            decision.signature = try keys.sign(decision.statement, context: context)
        }
        var command = Agentkeyring_V1_RelayWireRequest(); command.decide = decision
        var next = state
        next.requests[id]!.deliveryDecision = try decision.serializedData()
        next.outbox.append(try command.serializedData())
        try commit(next)
        logger.notice("Direct phone answer committed to durable outbox; approve=\(approving, privacy: .public)")
    }
}
