import AgentKeyringApprovalCore
import CloudKit
import CryptoKit
import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Phone and Mac approval parity")
@MainActor
struct PhoneApprovalParityTests {
    @Test("The phone signs a full encrypted CloudKit request and the Mac accepts every choice",
        arguments: ApprovalChoice.allCases, [ApprovalAction.fill, .acquire])
    func roundTrip(choice: ApprovalChoice, action: ApprovalAction) async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.pair()
        let request = try fixture.request(action: action)
        let verifier = fixture.verifier()
        try await verifier.register(request)

        let requestRecord = ApprovalCloudRecords.request(request)
        #expect(requestRecord["site"] == nil)
        #expect(requestRecord["account"] == nil)
        let phoneFields = try #require(ApprovalCloudRecords.signedFields(from: requestRecord))
        #expect(phoneFields == request.signedFields)
        #expect(phoneFields.canonicalBytes(for: choice) == request.signedFields.canonicalBytes(for: choice))

        let phoneDecision = try signOnPhone(phoneFields, choice: choice, key: fixture.phoneKey)
        let decisionRecord = ApprovalCloudRecords.decision(phoneDecision)
        #expect(decisionRecord.recordID.recordName == requestRecord.recordID.recordName)
        #expect(decisionRecord.recordID.zoneID == ApprovalCloudRecords.decisionZone)
        let macDecision = try #require(ApprovalCloudRecords.decision(from: decisionRecord, for: request))
        #expect(try await verifier.verify(macDecision) == choice)
        await #expect(throws: ApprovalDecisionRefusal.replayed) { try await verifier.verify(macDecision) }
    }

    @Test("A phone signature of changed CloudKit fields cannot authorize the retained Mac request",
        arguments: ["agentDisplayLabel", "site", "account", "field", "action", "oneTimeValue", "expiresAt"])
    func changedRequestField(field: String) async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.pair()
        let request = try fixture.request()
        let verifier = fixture.verifier()
        try await verifier.register(request)
        let record = ApprovalCloudRecords.request(request)
        switch field {
        case "agentDisplayLabel": record[field] = "Another agent"
        case "site": record.encryptedValues[field] = "https://changed.example"
        case "account": record.encryptedValues[field] = "changed-account"
        case "field": record[field] = AgentCredentialField.username.rawValue
        case "action": record[field] = ApprovalAction.acquire.rawValue
        case "oneTimeValue": record[field] = Data(repeating: 0, count: 32)
        case "expiresAt": record[field] = NSNumber(value: request.expiresAt + 1)
        default: Issue.record("Unexpected mutation")
        }
        let phoneFields = try #require(ApprovalCloudRecords.signedFields(from: record))
        let phoneDecision = try signOnPhone(phoneFields, choice: .approve, key: fixture.phoneKey)
        let macDecision = try #require(ApprovalCloudRecords.decision(
            from: ApprovalCloudRecords.decision(phoneDecision), for: request))
        await #expect(throws: ApprovalDecisionRefusal.invalidSignature) { try await verifier.verify(macDecision) }
        // The refusal leaves the original request available for an authentic decision.
        let original = try #require(ApprovalCloudRecords.signedFields(from: ApprovalCloudRecords.request(request)))
        #expect(try await verifier.verify(signOnPhone(original, choice: .approve, key: fixture.phoneKey)) == .approve)
    }

    @Test("A changed choice in the decision record invalidates the phone signature",
        arguments: [ApprovalChoice.deny, .blockThisLogin])
    func changedChoice(choice: ApprovalChoice) async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.pair()
        let request = try fixture.request()
        let verifier = fixture.verifier()
        try await verifier.register(request)
        let fields = try #require(ApprovalCloudRecords.signedFields(from: ApprovalCloudRecords.request(request)))
        let record = ApprovalCloudRecords.decision(try signOnPhone(fields, choice: .approve, key: fixture.phoneKey))
        record["choice"] = choice.rawValue
        let macDecision = try #require(ApprovalCloudRecords.decision(from: record, for: request))
        await #expect(throws: ApprovalDecisionRefusal.invalidSignature) { try await verifier.verify(macDecision) }
    }

    @Test("The record name binds the request ID on both sides")
    func changedRequestID() async throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        try await fixture.pair()
        let original = try fixture.request()
        let verifier = fixture.verifier()
        try await verifier.register(original)
        let originalRecord = ApprovalCloudRecords.request(original)
        let changedRecord = copyRequestRecord(originalRecord, recordID: ApprovalCloudRecords.requestID(UUID()))
        let changedFields = try #require(ApprovalCloudRecords.signedFields(from: changedRecord))
        let changedDecision = try signOnPhone(changedFields, choice: .approve, key: fixture.phoneKey)
        let decisionRecord = ApprovalCloudRecords.decision(changedDecision)
        #expect(ApprovalCloudRecords.decision(from: decisionRecord, for: original) == nil)
        await #expect(throws: ApprovalDecisionRefusal.unknownRequest) { try await verifier.verify(changedDecision) }
    }

    @Test("The phone rejects incomplete or malformed requests instead of signing push or plaintext fields",
        arguments: ["missing-site", "missing-account", "field", "action", "short-nonce", "expiry", "fractional-expiry", "boolean-expiry", "wrong-type", "wrong-zone", "invalid-id"])
    func malformedRequest(problem: String) throws {
        let fixture = PhoneApprovalFixture()
        defer { fixture.cleanUp() }
        let request = try fixture.request()
        var record = ApprovalCloudRecords.request(request)
        switch problem {
        case "missing-site":
            record.encryptedValues["site"] = nil
            record["site"] = request.site as CKRecordValue
        case "missing-account":
            record.encryptedValues["account"] = nil
            record["account"] = request.account as CKRecordValue
        case "field": record["field"] = "unknown-field"
        case "action": record["action"] = "unknown-action"
        case "short-nonce": record["oneTimeValue"] = Data([0])
        case "expiry": record["expiresAt"] = nil
        case "fractional-expiry": record["expiresAt"] = NSNumber(value: 1.5)
        case "boolean-expiry": record["expiresAt"] = NSNumber(value: true)
        case "wrong-type": record = copyRequestRecord(record, recordID: record.recordID, recordType: "ApprovalDecision")
        case "wrong-zone": record = copyRequestRecord(record, recordID: ApprovalCloudRecords.decisionID(request.id))
        case "invalid-id": record = copyRequestRecord(record, recordID: CKRecord.ID(recordName: "not-a-uuid", zoneID: ApprovalCloudRecords.requestZone))
        default: Issue.record("Unexpected malformed request")
        }
        #expect(ApprovalCloudRecords.signedFields(from: record) == nil)
    }

    private func copyRequestRecord(_ source: CKRecord, recordID: CKRecord.ID,
        recordType: String = "ApprovalRequest") -> CKRecord {
        let copy = CKRecord(recordType: recordType, recordID: recordID)
        for key in source.allKeys() { copy[key] = source[key] }
        for key in ["site", "account"] { copy.encryptedValues[key] = source.encryptedValues[key] }
        return copy
    }

    // CryptoKit replaces only the Secure Enclave key; encoding and record mapping
    // are the same functions that the phone handler and Mac verifier use.
    private func signOnPhone(_ fields: ApprovalSignedFields, choice: ApprovalChoice,
        key: P256.Signing.PrivateKey) throws -> ApprovalDecision {
        ApprovalDecision(requestID: fields.requestID, choice: choice,
            devicePublicKey: key.publicKey.x963Representation,
            signature: try key.signature(for: fields.canonicalBytes(for: choice)).derRepresentation)
    }
}
