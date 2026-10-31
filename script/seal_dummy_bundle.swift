// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// Proof fixture only. Inputs and outputs are private files containing dummy data.
import CryptoKit
import Foundation
let action = CommandLine.arguments[1]
let paths = CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
if action == "sign" {
    let key = try P256.Signing.PrivateKey(rawRepresentation: Data(contentsOf: paths[0]))
    try key.signature(for: Data(contentsOf: paths[1])).derRepresentation.write(to: paths[2])
} else {
    let key = try P256.KeyAgreement.PublicKey(x963Representation: Data(contentsOf: paths[0]))
    var sender = try HPKE.Sender(recipientKey: key, ciphersuite: .P256_SHA256_AES_GCM_256, info: Data("agentkeyring.bundle.v1".utf8))
    let ciphertext = try sender.seal(Data(contentsOf: paths[1]), authenticating: Data(contentsOf: paths[2]))
    try sender.encapsulatedKey.write(to: paths[3])
    try ciphertext.write(to: paths[4])
}
