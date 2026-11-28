// Written by AI on 2026.11.21 by model claude opus 5.5; answers in a box on 2026.11.23; Stop through a grant,
// and the doors cut, on 2026.11.24.
//
// A device's answer, put in the request's answer box at the relay (keyring.proto, "Boxes"), and its Stop,
// which marks the request's grant there. CredentialSealing.verifySignedLeaseRequest has checked the box is one this device may use.

import AgentKeyringProtocol
import Foundation

public enum AnswerBox {
    /// How long an answer that cannot reach the relay keeps trying.
    static let retryFor: TimeInterval = 30

    /// The relay could not be reached for `retryFor`, or refused the answer.
    struct NotDelivered: Error, CustomStringConvertible {
        let last: Error
        var description: String { "not delivered: \(last)" }
    }

    /// Another device's answer is already in the request's box: this one was not sent, and the
    /// outcome comes by push.
    public struct AlreadyAnswered: Error, CustomStringConvertible {
        public var description: String { "another device answered first" }
    }

    /// Puts an answer in the request's answer box. `bundle`: this device's signed lists, which go with the
    /// answer so the asking computer learns rule and device changes. A box says nothing more than that it
    /// took the answer, so the Lease returned is `.waiting`: sent, with the outcome to come by push.
    /// Another device's answer already in the box is `AlreadyAnswered`. `waiting` is called each time the
    /// relay is tried again.
    public static func answer(_ upload: AnswerUpload, for request: KeyringRequest, by label: String,
                              bundle: Agentkeyring_V2_Bundle? = nil, waiting: @Sendable () -> Void = {}) async throws -> Agentkeyring_V2_Lease {
        guard let relay = RelayBoxClient(for: request), !request.answerBoxID.isEmpty else { throw NotDelivered(last: RelayBoxError.refused(0)) }
        var sent = upload
        if let bundle { sent.bundle = bundle }
        do {
            try await relay.putRelayBox(sent.serializedData(), box: request.answerBoxID, key: request.answerBoxKey,
                                giveUp: .now.addingTimeInterval(retryFor), stillTrying: waiting)
        } catch RelayBoxError.exists {
            throw AlreadyAnswered()
        } catch let failure as RelayBoxError {
            throw NotDelivered(last: failure)
        }
        var lease = Agentkeyring_V2_Lease()
        lease.requestID = request.requestID
        lease.loginID = request.loginID
        lease.state = .waiting
        lease.answerByUnixSeconds = request.answerByUnixSeconds
        lease.answeredBy = label
        return lease
    }

    /// Stop: the request's grant is marked stopped for good, with the signed EndRequest (keyring.proto,
    /// "Grants and Stop"), and the computer refuses every use after. True once the relay says the grant
    /// is stopped; false if it took the Stop without saying so.
    public static func stopLeaseGrant(_ signed: SignedDocument, for request: KeyringRequest) async throws -> Bool {
        guard let relay = RelayBoxClient(for: request), !request.answerBoxID.isEmpty else { throw NotDelivered(last: RelayBoxError.refused(0)) }
        do {
            return try await relay.stopLeaseGrantBox(answerBox: request.answerBoxID, key: request.answerBoxKey, requestID: request.requestID,
                                        signedEnd: signed.serializedData())
        } catch let failure as RelayBoxError {
            throw NotDelivered(last: failure)
        }
    }
}
