// Written by AI on 2026.11.23 by model claude opus 5.5; part nonces, grants and mailboxes on 2026.11.24.
//
// The golden vectors the command checks too (internal/box, TestBoxVectors), so
// a code the Mac shows joins a computer running the Go command, and a box one
// side seals the other opens: a code as a person types it, its keys and boxes,
// a message sealed into one box and into two, a grant, and a mailbox slot.

import AgentKeyringSealing
import CryptoKit
import Foundation
import Testing

private struct Vectors: Decodable {
    struct Code: Decodable { let secret: String, code: String, typed: [String] }
    struct Link: Decodable { let relay: String, text: String }
    struct Join: Decodable {
        let secret: String, request_box: String, request_key: String, response_box: String, response_key: String, proof: String
    }
    struct Seal: Decodable {
        let box: String, key: String, message: String, nonce: String, part_nonce: String, plaintext: String, sealed: String, part_1_box: String
    }
    struct Grant: Decodable { let box: String, read_auth: String, write_auth: String }
    struct Mailbox: Decodable { let seed: String, device: String, slot: String, key: String }
    struct Parts: Decodable { let length: Int, nonces: [String], sealed_lengths: [Int], sealed_sha256: [String] }
    let codes: [Code]
    let not_codes: [String]
    let link: Link
    let join: Join
    let seal: Seal
    let grant: Grant
    let mailbox: Mailbox
    let parts: Parts

    static func load() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../testdata/box/vectors.json").standardized
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }
}

private func unhex(_ text: String) -> Data {
    Data(stride(from: 0, to: text.count, by: 2).map { UInt8(text.dropFirst($0).prefix(2), radix: 16)! })
}

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

@Test func boxesMatchTheCommandByteForByte() throws {
    let v = try Vectors.load()

    for c in v.codes {
        #expect(ComputerJoinCode(secret: unhex(c.secret)).code == c.code)
        for typed in c.typed + [c.code] {
            #expect(ComputerJoinCode(parsing: typed)?.secret == unhex(c.secret), "\(typed)")
        }
    }
    for typed in v.not_codes { #expect(ComputerJoinCode(parsing: typed) == nil, "\(typed)") }
    let linked = ComputerJoinCode(secret: unhex(v.join.secret), relay: v.link.relay)
    #expect(linked.link == v.link.text)
    #expect(ComputerJoinCode(parsing: v.link.text) == linked)

    let keys = ComputerJoinCode(secret: unhex(v.join.secret)).keys
    #expect(keys.requestBox == v.join.request_box)
    #expect(hex(keys.requestKey) == v.join.request_key)
    #expect(keys.responseBox == v.join.response_box)
    #expect(hex(keys.responseKey) == v.join.response_key)
    #expect(hex(keys.proof) == v.join.proof)

    let one = RelayBoxProtocol.splitIntoBoxChunks(Data(v.seal.message.utf8), box: v.seal.box, nonce: unhex(v.seal.part_nonce))
    #expect(one.map(\.id) == [v.seal.box])
    let plaintext = one.map(\.plaintext)
    #expect(plaintext.map(hex) == [v.seal.plaintext])
    let sealed = try RelayBoxProtocol.sealBoxChunk(plaintext[0], box: v.seal.box, key: unhex(v.seal.key), nonce: unhex(v.seal.nonce))
    #expect(hex(sealed) == v.seal.sealed)
    #expect(try RelayBoxProtocol.openBoxChunk(unhex(v.seal.sealed), box: v.seal.box, key: unhex(v.seal.key)) == plaintext[0])
    // Bound to its box: the relay cannot hand one box's message over as another's.
    #expect(throws: RelayBoxError.unreadable) { try RelayBoxProtocol.openBoxChunk(unhex(v.seal.sealed), box: v.seal.part_1_box, key: unhex(v.seal.key)) }
    #expect(RelayBoxProtocol.partID(nonce: unhex(v.seal.part_nonce), 1) == v.seal.part_1_box)
    let grant = LeaseGrantBox(answerBox: v.seal.box, key: unhex(v.seal.key))
    #expect([grant.id, grant.readAuth, grant.writeAuth] == [v.grant.box, v.grant.read_auth, v.grant.write_auth])
    #expect(RelayBoxProtocol.mailboxSlot(seed: unhex(v.mailbox.seed), deviceKeyID: v.mailbox.device) == v.mailbox.slot)
    #expect(hex(RelayBoxProtocol.mailboxKey(seed: unhex(v.mailbox.seed))) == v.mailbox.key)

    let message = Data((0..<v.parts.length).map { UInt8($0 % 251) })
    let parts = RelayBoxProtocol.splitIntoBoxChunks(message, box: v.join.response_box, nonce: unhex(v.seal.part_nonce))
    #expect(parts.count == v.parts.nonces.count)
    for (index, part) in parts.enumerated() {
        let sealed = try RelayBoxProtocol.sealBoxChunk(part.plaintext, box: part.id, key: unhex(v.join.response_key),
                                      nonce: unhex(v.parts.nonces[index]))
        #expect(sealed.count == v.parts.sealed_lengths[index])
        #expect(hex(Data(SHA256.hash(data: sealed))) == v.parts.sealed_sha256[index])
    }
}
