// Written by AI on 2026.11.20 by model Claude Opus 5.5; signed practice requests and answer doors on 2026.11.21;
// answer boxes in place of doors on 2026.11.24.
// A practice request is signed by the computer that made it; a computer's
// request carries its signature, and names an answer box at a relay the
// device may use. On 20 Nov the iPhone read every practice notice as unsigned
// and showed "An agent wants to use a password." instead of its words; a
// carrier that could point the answers at another relay would receive every
// answer meant for the asking computer.

import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import Testing

struct PracticeRequestTests {
    static let computerKey = P256.Signing.PrivateKey()
    static let otherKey = P256.Signing.PrivateKey()

    static var members: Members {
        var machine = Agentkeyring_V2_Machine()
        machine.machineID = "mini"; machine.label = "Mac mini"; machine.tlsPublicKey = computerKey.publicKey.derRepresentation
        var members = Members()
        members.machines = [machine]
        return members
    }

    static func envelope(practiceFor device: String? = nil, signer: P256.Signing.PrivateKey? = nil,
                     relay: String = "") throws -> Agentkeyring_V2_SignedRequestEnvelope {
        var request = KeyringRequest()
        request.domain = "agentkeyring.request.v2"; request.requestID = "r1"
        request.machineID = "mini"
        if let device { request.forDeviceKeyID = device } else { request.loginID = "example" }
        request.answerBoxID = String(repeating: "ab", count: 32)
        request.answerBoxKey = Data(repeating: 7, count: 32)
        request.answerBoxURL = relay
        var envelope = Agentkeyring_V2_SignedRequestEnvelope()
        envelope.request = try request.serializedData()
        if let signer { envelope.requestSignature = try signer.signature(for: envelope.request).derRepresentation }
        return envelope
    }

    @Test func aPracticeRequestTheComputerSignedIsRecognised() throws {
        #expect(try isOwnPractice(Self.envelope(practiceFor: "watch", signer: Self.computerKey), members: Self.members, ownKeyID: "watch"))
    }

    @Test func aComputersSignedRequestIsNotAPractice() throws {
        let envelope = try Self.envelope(signer: Self.computerKey)
        #expect(try !isOwnPractice(envelope, members: Self.members, ownKeyID: "watch"))
    }

    @Test func unsignedRequestsAndAnswersSentElsewhereAreRefused() throws {
        #expect(throws: UnsignedWatchRequestError.self) { try isOwnPractice(Self.envelope(practiceFor: "watch"), members: Self.members, ownKeyID: "watch") }
        #expect(throws: UnsignedWatchRequestError.self) { try isOwnPractice(Self.envelope(practiceFor: "watch", signer: Self.otherKey), members: Self.members, ownKeyID: "watch") }
        #expect(throws: UnsignedWatchRequestError.self) { try isOwnPractice(Self.envelope(practiceFor: "iphone", signer: Self.computerKey), members: Self.members, ownKeyID: "watch") }
        let elsewhere = try Self.envelope(signer: Self.computerKey, relay: "https://relay.elsewhere.example")
        #expect(throws: UnsignedWatchRequestError.self) { try isOwnPractice(elsewhere, members: Self.members, ownKeyID: "watch") }
    }
}
