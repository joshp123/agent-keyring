// Written by AI on 2026.11.18 by model claude opus 5.5.
// Sitting test only, on a local branch that is never merged. After the panel's
// one Touch ID or Watch approval, use that same approval to open a sealed
// example login with a chip key and sign an answer with a second chip key.
// Any step that would need another prompt fails instead of asking.

import CryptoKit
import Foundation
import LocalAuthentication
import Security

public enum SittingProbe {
    static let example = Data(#"{"site":"example.com","account":"example@example.com","password":"example-password"}"#.utf8)
    static let label = Data("this-mac|login-example".utf8)

    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "AgentKeyringSitting")
    }

    static func access() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryAny, .or, .companion], &error) else { throw error!.takeRetainedValue() as Error }
        return control
    }

    /// Creates the two chip keys and the sealed example once. Needs no approval.
    static func prepare() throws -> (opener: Data, signer: Data, box: (Data, Data)) {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let openerURL = folder.appending(path: "opener.key"), signerURL = folder.appending(path: "signer.key")
        let boxURL = folder.appending(path: "example.box")
        if let opener = try? Data(contentsOf: openerURL), let signer = try? Data(contentsOf: signerURL),
           let box = try? JSONDecoder().decode([Data].self, from: Data(contentsOf: boxURL)), box.count == 2 {
            return (opener, signer, (box[0], box[1]))
        }
        let opener = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access())
        let signer = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access())
        var sender = try HPKE.Sender(recipientKey: opener.publicKey, ciphersuite: .P256_SHA256_AES_GCM_256,
                                     info: Data("agentkeyring.login.v2".utf8))
        let ciphertext = try sender.seal(example, authenticating: label)
        try opener.dataRepresentation.write(to: openerURL)
        try signer.dataRepresentation.write(to: signerURL)
        try JSONEncoder().encode([sender.encapsulatedKey, ciphertext]).write(to: boxURL)
        return (opener.dataRepresentation, signer.dataRepresentation, (sender.encapsulatedKey, ciphertext))
    }

    /// At launch: create the chip keys and the sealed example, needing no approval.
    public static func prepareAndRecord() {
        var result: [String: Any] = ["request": "launch", "at": ISO8601DateFormatter().string(from: Date())]
        do { _ = try prepare(); result["prepared"] = true }
        catch { let ns = error as NSError; result["error"] = "\(ns.domain) \(ns.code): \(ns.localizedDescription)" }
        append(result)
    }

    static func append(_ result: [String: Any]) {
        guard let line = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return }
        let url = folder.appending(path: "results.jsonl")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(line + Data("\n".utf8)); try? handle.close()
        } else { try? (line + Data("\n".utf8)).write(to: url) }
    }

    /// Call right after the panel's approval succeeded, with its context.
    public static func run(context: LAContext, request: String) {
        var result: [String: Any] = ["request": request, "at": ISO8601DateFormatter().string(from: Date())]
        let probe = LAContext()
        result["touchIDAvailableNow"] = probe.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        context.interactionNotAllowed = true
        let started = Date()
        do {
            let keys = try prepare()
            let opener = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: keys.opener, authenticationContext: context)
            var recipient = try HPKE.Recipient(privateKey: opener, ciphersuite: .P256_SHA256_AES_GCM_256,
                info: Data("agentkeyring.login.v2".utf8), encapsulatedKey: keys.box.0)
            var plain = try recipient.open(keys.box.1, authenticating: label)
            result["opened"] = plain == example
            // Seal again for an asking machine (a throwaway key here) and check it.
            let machine = P256.KeyAgreement.PrivateKey()
            var sender = try HPKE.Sender(recipientKey: machine.publicKey, ciphersuite: .P256_SHA256_AES_GCM_256,
                                         info: Data("agentkeyring.bundle.v1".utf8))
            let resealed = try sender.seal(plain, authenticating: Data(request.utf8))
            plain.resetBytes(in: plain.startIndex..<plain.endIndex)
            var check = try HPKE.Recipient(privateKey: machine, ciphersuite: .P256_SHA256_AES_GCM_256,
                info: Data("agentkeyring.bundle.v1".utf8), encapsulatedKey: sender.encapsulatedKey)
            result["resealed"] = try check.open(resealed, authenticating: Data(request.utf8)) == example
            let signer = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keys.signer, authenticationContext: context)
            let statement = Data("approve|\(request)".utf8)
            let signature = try signer.signature(for: statement)
            result["signed"] = signer.publicKey.isValidSignature(signature, for: statement)
        } catch {
            let ns = error as NSError
            result["error"] = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        }
        result["milliseconds"] = Int(Date().timeIntervalSince(started) * 1000)
        append(result)
    }
}
