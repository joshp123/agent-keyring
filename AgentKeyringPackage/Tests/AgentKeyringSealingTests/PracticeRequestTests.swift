// Written by AI on 2026.11.20 by model Claude Opus 5.5; signed practice requests and answer doors on 2026.11.21.
// A practice request is signed, by the computer that made it or by the relay
// for one a device asked it for; a computer's request carries its signature,
// and its answer door serves with that computer's key. On 20 Nov the iPhone
// read every practice notice as unsigned and showed "An agent wants to use a
// password." instead of its words; a relay that could swap the door would
// receive every answer meant for the asking computer.

import AgentKeyringProtocol
import AgentKeyringSealing
import AgentKeyringWatchCore
import CryptoKit
import Foundation
import Testing

struct PracticeRequestTests {
    static let computerKey = P256.Signing.PrivateKey()
    static let relayKey = P256.Signing.PrivateKey()

    static var members: Members {
        var machine = Agentkeyring_V2_Machine()
        machine.machineID = "mini"; machine.label = "Mac mini"; machine.tlsPublicKey = computerKey.publicKey.derRepresentation
        var members = Members()
        members.machines = [machine]
        members.relayTlsPublicKey = relayKey.publicKey.derRepresentation
        return members
    }

    static func work(practiceFor device: String? = nil, signer: P256.Signing.PrivateKey? = nil,
                     door: Data? = nil) throws -> Agentkeyring_V2_Work {
        var request = KeyringRequest()
        request.domain = "agentkeyring.request.v2"; request.requestID = "r1"
        if let device { request.forDeviceKeyID = device } else { request.machineID = "mini"; request.loginID = "example" }
        if let door { request.answerAddress = "100.64.0.20:17446"; request.answerTlsPublicKey = door }
        var work = Agentkeyring_V2_Work()
        work.request = try request.serializedData()
        if let signer { work.requestSignature = try signer.signature(for: work.request).derRepresentation }
        return work
    }

    @Test func aPracticeRequestTheRelaySignedIsRecognised() throws {
        #expect(try isOwnPractice(Self.work(practiceFor: "watch", signer: Self.relayKey), members: Self.members, ownKeyID: "watch"))
    }

    @Test func aComputersSignedRequestIsNotAPractice() throws {
        let work = try Self.work(signer: Self.computerKey, door: Self.computerKey.publicKey.derRepresentation)
        #expect(try !isOwnPractice(work, members: Self.members, ownKeyID: "watch"))
    }

    @Test func unsignedRequestsAndForeignDoorsAreRefused() throws {
        #expect(throws: UnsignedRequest.self) { try isOwnPractice(Self.work(practiceFor: "watch"), members: Self.members, ownKeyID: "watch") }
        #expect(throws: UnsignedRequest.self) { try isOwnPractice(Self.work(practiceFor: "iphone", signer: Self.relayKey), members: Self.members, ownKeyID: "watch") }
        let swapped = try Self.work(signer: Self.computerKey, door: Self.relayKey.publicKey.derRepresentation)
        #expect(throws: UnsignedRequest.self) { try isOwnPractice(swapped, members: Self.members, ownKeyID: "watch") }
    }
}
