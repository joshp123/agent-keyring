// Written by AI on 2026.11.20 by model Claude Opus 5.5.
// A device's own practice request carries no computer's signature; a
// computer's request must carry its signature. On 20 Nov the iPhone read every
// practice notice as unsigned, because `try?` flattened "no computer" into
// "failed", and showed "An agent wants to use a password." instead of its words.

import AgentKeyringProtocol
import AgentKeyringSealing
import AgentKeyringWatchCore
import CryptoKit
import Foundation
import Testing

struct PracticeRequestTests {
    static let computerKey = P256.Signing.PrivateKey()

    static var members: Members {
        var machine = Agentkeyring_V2_Machine()
        machine.machineID = "mini"; machine.label = "Mac mini"; machine.tlsPublicKey = computerKey.publicKey.derRepresentation
        var members = Members()
        members.machines = [machine]
        return members
    }

    static func work(practiceFor device: String? = nil, signed: Bool = false) throws -> Agentkeyring_V2_Work {
        var request = KeyringRequest()
        request.domain = "agentkeyring.request.v2"; request.requestID = "r1"
        if let device { request.forDeviceKeyID = device } else { request.machineID = "mini"; request.loginID = "example" }
        var work = Agentkeyring_V2_Work()
        work.request = try request.serializedData()
        if signed { work.requestSignature = try computerKey.signature(for: work.request).derRepresentation }
        return work
    }

    @Test func aDevicesOwnPracticeRequestIsRecognised() throws {
        #expect(try isOwnPractice(Self.work(practiceFor: "watch"), members: Self.members, ownKeyID: "watch"))
    }

    @Test func aComputersSignedRequestIsNotAPractice() throws {
        #expect(try !isOwnPractice(Self.work(signed: true), members: Self.members, ownKeyID: "watch"))
    }

    @Test func anUnsignedRequestIsRefusedEvenDressedAsAnotherDevicesPractice() throws {
        #expect(throws: UnsignedRequest.self) { try isOwnPractice(Self.work(), members: Self.members, ownKeyID: "watch") }
        #expect(throws: UnsignedRequest.self) { try isOwnPractice(Self.work(practiceFor: "iphone"), members: Self.members, ownKeyID: "watch") }
    }
}
