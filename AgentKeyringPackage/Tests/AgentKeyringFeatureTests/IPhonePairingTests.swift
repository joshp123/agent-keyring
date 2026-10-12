import AgentKeyringApprovalCore
import AgentKeyringTestSupport
import CloudKit
import CryptoKit
import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("QR pairing through CloudKit")
@MainActor
struct IPhonePairingTests {
    @Test("A scanned QR pairs only after signed-store confirmation, then removal revokes it")
    func validPairingAndRemoval() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: fixture.store)
        let database = InMemoryApprovalCloudDatabase()
        let controller = CredentialAccessController(store: fixture.store)
        let session = try IPhonePairingSession(database: database)
        let code = try #require(session.code)
        let scanned = try PairingCode(qrPayload: code.qrPayload)
        #expect(scanned.id == code.id)
        #expect(scanned.secret == code.secret)
        let request = PairingRequest(code: scanned, publicKey: fixture.device.publicKey, deviceName: fixture.device.name)
        let record = PairingCloudRecords.record(request)
        #expect(record.allKeys().sorted() == ["authenticationCode", "deviceName", "publicKey"])
        #expect(database.records.isEmpty) // The Mac never publishes the secret or a challenge record.
        try await database.save(record)
        let received = try #require(try await session.poll())
        #expect(received.publicKey == fixture.device.publicKey)
        #expect(PairingRequest.fingerprint(publicKey: received.publicKey) == PairingRequest.fingerprint(publicKey: fixture.device.publicKey))
        #expect(try await fixture.store.loadPairedDevices().isEmpty)
        #expect(database.records.isEmpty)
        try await controller.confirmPairing(session, confirmationCode: PairingRequest.confirmationCode(publicKey: fixture.device.publicKey))
        #expect(controller.hasPairedApprovalDevice)
        #expect(controller.pairedApprovalDevices.map(\.publicKey) == [fixture.device.publicKey])
        #expect(try await fixture.store.loadPairedDevices().map(\.publicKey) == [fixture.device.publicKey])
        try await controller.removePairedApprovalDevice(publicKey: fixture.device.publicKey)
        #expect(!controller.hasPairedApprovalDevice)
        #expect(controller.pairedApprovalDevices.isEmpty)
        #expect(try await fixture.store.loadPairedDevices().isEmpty)
        #expect(fixture.signer.signingReason == "remove your paired iPhone from Agent Keyring")
    }

    @Test("Wrong secret, altered key/name, and no QR cannot establish trust", arguments: ["wrong-secret", "key", "name", "no-qr", "malformed"])
    func forgedRequest(attack: String) async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: fixture.store)
        let database = InMemoryApprovalCloudDatabase()
        let session = try IPhonePairingSession(database: database)
        let code = try #require(session.code)
        let original = PairingRequest(code: code, publicKey: fixture.device.publicKey, deviceName: "Test iPhone")
        var wrongSecretQR = try #require(URLComponents(string: code.qrPayload))
        wrongSecretQR.queryItems = [URLQueryItem(name: "secret", value: try PairingCode().secret.base64EncodedString()),
            URLQueryItem(name: "expires", value: String(code.expiresAt.timeIntervalSince1970))]
        let other = PairingRequest(code: try PairingCode(qrPayload: wrongSecretQR.string!),
            publicKey: fixture.device.publicKey, deviceName: "Test iPhone")
        let request = PairingRequest(pairingID: code.id,
            publicKey: attack == "key" ? P256.Signing.PrivateKey().publicKey.x963Representation : original.publicKey,
            deviceName: attack == "name" ? "Attacker iPhone" : original.deviceName,
            authenticationCode: attack == "no-qr" ? Data() : attack == "wrong-secret" ? other.authenticationCode : original.authenticationCode)
        let record = PairingCloudRecords.record(request)
        if attack == "malformed" { record["deviceName"] = nil }
        try await database.save(record)
        await #expect(throws: PairingFailure.self) { try await session.poll() }
        await #expect(throws: PairingFailure.alreadyUsed) { try await session.confirm(in: fixture.store, confirmationCode: PairingRequest.confirmationCode(publicKey: fixture.device.publicKey)) }
        #expect(session.code == nil)
        #expect(database.records.isEmpty)
        #expect(database.deletedRecordIDs == [record.recordID])
        #expect(try await fixture.store.loadPairedDevices().isEmpty)
    }

    @Test("Expiry refuses the record and deletes it, including expiry while comparing fingerprints", arguments: [true, false])
    func expiry(beforePoll: Bool) async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: fixture.store)
        let database = InMemoryApprovalCloudDatabase()
        let session = try IPhonePairingSession(database: database)
        let code = try #require(session.code)
        try await database.save(PairingCloudRecords.record(PairingRequest(code: code, publicKey: fixture.device.publicKey, deviceName: "Test iPhone")))
        if beforePoll {
            await #expect(throws: PairingFailure.expired) { try await session.poll(now: code.expiresAt) }
        } else {
            _ = try await session.poll()
            await #expect(throws: PairingFailure.expired) { try await session.confirm(in: fixture.store, confirmationCode: PairingRequest.confirmationCode(publicKey: fixture.device.publicKey), now: code.expiresAt) }
        }
        #expect(database.records.isEmpty)
        #expect(try await fixture.store.loadPairedDevices().isEmpty)
    }

    @Test("A consumed pairing ID cannot be used twice or in a new session")
    func replay() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: fixture.store)
        let database = InMemoryApprovalCloudDatabase()
        let session = try IPhonePairingSession(database: database)
        let code = try #require(session.code)
        let record = PairingCloudRecords.record(PairingRequest(code: code, publicKey: fixture.device.publicKey, deviceName: "Test iPhone"))
        try await database.save(record)
        _ = try await session.poll()
        try await session.confirm(in: fixture.store, confirmationCode: PairingRequest.confirmationCode(publicKey: fixture.device.publicKey))
        await #expect(throws: PairingFailure.alreadyUsed) { try await session.confirm(in: fixture.store, confirmationCode: PairingRequest.confirmationCode(publicKey: fixture.device.publicKey)) }
        try await database.save(record)
        await #expect(throws: PairingFailure.alreadyUsed) { try await session.poll() }
        let newSession = try IPhonePairingSession(database: database)
        #expect(try await newSession.poll() == nil)
        try await session.cancel()
        #expect(database.records.isEmpty)
    }

    @Test("Cancelling the fingerprint confirmation and cancelling Touch ID both leave trust unchanged", arguments: [true, false])
    func cancellation(beforeTouchID: Bool) async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: fixture.store)
        let database = InMemoryApprovalCloudDatabase()
        let session = try IPhonePairingSession(database: database)
        let code = try #require(session.code)
        try await database.save(PairingCloudRecords.record(PairingRequest(code: code, publicKey: fixture.device.publicKey, deviceName: "Test iPhone")))
        _ = try await session.poll()
        if beforeTouchID {
            try await session.cancel()
            await #expect(throws: PairingFailure.alreadyUsed) { try await session.confirm(in: fixture.store, confirmationCode: PairingRequest.confirmationCode(publicKey: fixture.device.publicKey)) }
        } else {
            fixture.signer.refuseSigning()
            await #expect(throws: CocoaError.self) { try await session.confirm(in: fixture.store, confirmationCode: PairingRequest.confirmationCode(publicKey: fixture.device.publicKey)) }
        }
        #expect(database.records.isEmpty)
        #expect(try await fixture.store.loadPairedDevices().isEmpty)
    }

    @Test("Closing pairing deletes the phone record even from an already cancelled task")
    func cancelledTaskCleanup() async throws {
        let database = InMemoryApprovalCloudDatabase()
        let session = try IPhonePairingSession(database: database)
        let code = try #require(session.code)
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        try await database.save(PairingCloudRecords.record(PairingRequest(code: code,
            publicKey: key, deviceName: "Test iPhone")))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await session.cancel()
        }
        try await task.value
        #expect(session.code == nil)
        #expect(database.records.isEmpty)
        #expect(database.deletedRecordIDs == [PairingCloudRecords.recordID(code.id)])
    }

    @Test("The phone code must match the received key before Touch ID can pair it")
    func confirmationCodeMatchAndMismatch() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await confirmInitialAccessRules(in: fixture.store)
        let database = InMemoryApprovalCloudDatabase()
        let session = try IPhonePairingSession(database: database)
        let code = try #require(session.code)
        try await database.save(PairingCloudRecords.record(PairingRequest(code: code,
            publicKey: fixture.device.publicKey, deviceName: "Test iPhone")))
        _ = try await session.poll()
        let expected = PairingRequest.confirmationCode(publicKey: fixture.device.publicKey)
        #expect(expected.count == 6)
        #expect(expected.allSatisfy { $0.isNumber })
        let wrong = expected == "000000" ? "000001" : "000000"
        let controller = CredentialAccessController(store: fixture.store)
        await #expect(throws: PairingFailure.confirmationCodeMismatch) {
            try await controller.confirmPairing(session, confirmationCode: wrong)
        }
        #expect(try await fixture.store.loadPairedDevices().isEmpty)
        try await controller.confirmPairing(session, confirmationCode: expected)
        #expect(fixture.signer.signingReason == "pair Test iPhone with Agent Keyring, code \(expected)")
        #expect(try await fixture.store.loadPairedDevices().count == 1)
        #expect(PairingRequest.confirmationCode(publicKey: Data()) == "012610")
    }

    @Test("Canonical bytes are unambiguous and match the v1 wire vector")
    func canonicalBytes() throws {
        let id = try #require(UUID(uuidString: "00010203-0405-0607-0809-0A0B0C0D0E0F"))
        let bytes = PairingRequest.canonicalBytes(pairingID: id, publicKey: Data([0xAA, 0xBB]), deviceName: "é")
        let expected = Data("AgentKeyring.pairing.v1\0".utf8) + Data(0...15) + Data([0, 0, 0, 2, 0xAA, 0xBB, 0, 0, 0, 2, 0xC3, 0xA9])
        #expect(bytes == expected)
        #expect(PairingRequest.canonicalBytes(pairingID: id, publicKey: Data([0xAA]), deviceName: "bc") != PairingRequest.canonicalBytes(pairingID: id, publicKey: Data([0xAA, 0x62]), deviceName: "c"))
    }

    @Test("QR parser refuses a missing/short secret and an expired QR")
    func qrValidation() throws {
        let code = try PairingCode()
        #expect(throws: PairingFailure.invalidCode) { try PairingCode(qrPayload: "agent-keyring://pair/v1/\(code.id)") }
        var shortSecret = try #require(URLComponents(string: code.qrPayload))
        shortSecret.queryItems = [URLQueryItem(name: "secret", value: "AA=="), URLQueryItem(name: "expires", value: String(code.expiresAt.timeIntervalSince1970))]
        #expect(throws: PairingFailure.invalidCode) { try PairingCode(qrPayload: shortSecret.string!) }
        #expect(throws: PairingFailure.expired) { try PairingCode(qrPayload: code.qrPayload, now: code.expiresAt) }
    }
}
