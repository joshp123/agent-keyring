import CryptoKit
import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Paired devices in the signed rules store")
struct PairedApprovalDeviceTests {
    @Test("Pairing and removal sign the same store, preserve rules, and survive reopening")
    func signedDeviceChanges() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        let loginID = UUID()
        try await fixture.store.save([loginID: .block])
        let oldHash = try fixture.signer.signedBytesHash()
        try await fixture.store.addPairedDevice(fixture.device)
        #expect(fixture.signer.signingReason == "pair your iPhone with Agent Keyring")
        #expect(try fixture.signer.signedBytesHash() != oldHash)
        let reopened = CredentialAccessPolicyStore(fileURL: fixture.fileURL, signer: fixture.signer)
        #expect(try await reopened.loadPairedDevices() == [fixture.device])
        #expect(try await reopened.load() == [loginID: .block])
        try await reopened.save([loginID: .allowAutomatically])
        #expect(try await reopened.loadPairedDevices() == [fixture.device])
        #expect(try await reopened.load() == [loginID: .allowAutomatically])
        let pairedHash = try fixture.signer.signedBytesHash()
        try await reopened.removePairedDevice(publicKey: fixture.device.publicKey)
        #expect(fixture.signer.signingReason == "remove your paired iPhone from Agent Keyring")
        #expect(try fixture.signer.signedBytesHash() != pairedHash)
        #expect(try await reopened.loadPairedDevices().isEmpty)
        #expect(try await reopened.load() == [loginID: .allowAutomatically])
        let bytes = try Data(contentsOf: fixture.fileURL)
        #expect(try fixture.signer.verify(Data(contentsOf: fixture.signatureURL), for: bytes))
        #expect(try fixture.signer.signedBytesHash() == Data(SHA256.hash(data: bytes)))
    }

    @Test("Cancelled Touch ID signing leaves both files and the trusted hash unchanged", arguments: [true, false])
    func cancelledDeviceChange(adding: Bool) async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.pair()
        let bytes = try Data(contentsOf: fixture.fileURL)
        let signature = try Data(contentsOf: fixture.signatureURL)
        let hash = try fixture.signer.signedBytesHash()
        fixture.signer.refuseSigning()
        await #expect(throws: CocoaError.self) {
            if adding {
                let second = PairedApprovalDevice(publicKey: P256.Signing.PrivateKey().publicKey, name: "Second test iPhone")
                try await fixture.store.addPairedDevice(second)
            } else {
                try await fixture.store.removePairedDevice(publicKey: fixture.device.publicKey)
            }
        }
        #expect(try Data(contentsOf: fixture.fileURL) == bytes)
        #expect(try Data(contentsOf: fixture.signatureURL) == signature)
        #expect(try fixture.signer.signedBytesHash() == hash)
        #expect(try await fixture.store.loadPairedDevices() == [fixture.device])
    }

    @Test("A public key inserted by hand fails closed for devices, rules and decisions")
    func handEditedPairing() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        let loginID = UUID()
        try await fixture.store.save([loginID: .block])
        let request = fixture.request()
        let verifier = fixture.verifier()
        try await verifier.register(request)
        var contents = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.fileURL)) as? [String: Any])
        let deviceObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.device))
        contents["pairedDevices"] = [deviceObject]
        try JSONSerialization.data(withJSONObject: contents, options: [.sortedKeys]).write(to: fixture.fileURL)
        await #expect(throws: AccessRulesConfirmationRequired.self) { try await fixture.store.load() }
        await #expect(throws: AccessRulesConfirmationRequired.self) { try await fixture.store.loadPairedDevices() }
        await #expect(throws: ApprovalDecisionRefusal.untrustedPairedDevices) {
            try await verifier.verify(fixture.decision(request.signedFields))
        }
        // The existing rule-confirmation path cannot quietly pair the attacker's key.
        let snapshot = try await fixture.store.snapshotForConfirmation()
        try await fixture.store.save(snapshot, reason: "confirm test rules")
        #expect(try await fixture.store.load() == [loginID: .block])
        #expect(try await fixture.store.loadPairedDevices().isEmpty)
        await #expect(throws: ApprovalDecisionRefusal.unpairedDevice) {
            try await verifier.verify(fixture.decision(request.signedFields))
        }
    }

    @Test("Restoring a valid old pairing after removal fails rollback protection")
    func pairingRollback() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.pair()
        let pairedBytes = try Data(contentsOf: fixture.fileURL)
        let pairedSignature = try Data(contentsOf: fixture.signatureURL)
        try await fixture.store.removePairedDevice(publicKey: fixture.device.publicKey)
        try pairedBytes.write(to: fixture.fileURL)
        try pairedSignature.write(to: fixture.signatureURL)
        #expect(try fixture.signer.verify(pairedSignature, for: pairedBytes))
        await #expect(throws: AccessRulesConfirmationRequired.self) { try await fixture.store.loadPairedDevices() }
        let request = fixture.request()
        let verifier = fixture.verifier()
        try await verifier.register(request)
        await #expect(throws: ApprovalDecisionRefusal.untrustedPairedDevices) {
            try await verifier.verify(fixture.decision(request.signedFields))
        }
    }

    @Test("A stale rule snapshot cannot restore a removed device")
    func staleConfirmation() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.pair()
        let snapshot = try await fixture.store.snapshotForConfirmation()
        try await fixture.store.removePairedDevice(publicKey: fixture.device.publicKey)
        await #expect(throws: AccessRulesConfirmationRequired.self) {
            try await fixture.store.save(snapshot, reason: "confirm test rules")
        }
        #expect(try await fixture.store.loadPairedDevices().isEmpty)
    }

    @Test("Confirming an earlier rule snapshot preserves a newly paired device")
    func preserveNewPairing() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.store.save([:])
        let snapshot = try await fixture.store.snapshotForConfirmation()
        try await fixture.store.addPairedDevice(fixture.device)
        try await fixture.store.save(snapshot, reason: "confirm test rules")
        #expect(try await fixture.store.loadPairedDevices() == [fixture.device])
    }

    @Test("Existing signed version-1 rules load without devices and upgrade when paired")
    func existingRules() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.store.save([:])
        let loginID = UUID()
        let legacyBytes = Data("{\"version\":1,\"records\":[{\"credentialID\":\"\(loginID)\",\"policy\":\"block\"}]}".utf8)
        let signature = try await fixture.signer.sign(legacyBytes, reason: "legacy fixture")
        try legacyBytes.write(to: fixture.fileURL)
        try signature.write(to: fixture.signatureURL)
        #expect(try await fixture.store.load() == [loginID: .block])
        #expect(try await fixture.store.loadPairedDevices().isEmpty)
        try await fixture.store.addPairedDevice(fixture.device)
        #expect(try await fixture.store.loadPairedDevices() == [fixture.device])
        #expect(try await fixture.store.load() == [loginID: .block])
    }
}
