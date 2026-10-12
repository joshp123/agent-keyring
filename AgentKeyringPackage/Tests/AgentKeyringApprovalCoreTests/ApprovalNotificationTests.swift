import AgentKeyringApprovalCore
import CloudKit
import Foundation
import Testing

@Suite("Approval notification and signature share record values")
struct ApprovalNotificationTests {
    @Test("Plaintext site cannot replace a missing encrypted site")
    func missingEncryptedSite() throws {
        let request = try ApprovalRequest(agentDisplayLabel: "Test agent", site: "example.com",
            account: "synthetic", field: .password, action: .fill)
        let record = ApprovalCloudRecords.request(request)
        record.encryptedValues["site"] = nil
        record["site"] = "wrong.example"
        #expect(ApprovalCloudRecords.signedFields(from: record) == nil)
    }

    @Test("Display strings and canonical bytes use the fetched fields, ignoring notification templates",
        arguments: AgentCredentialField.allCases, [ApprovalAction.fill, .acquire])
    func displayAndSignature(field: AgentCredentialField, action: ApprovalAction) throws {
        let request = try ApprovalRequest(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            agentDisplayLabel: "Test agent", site: "https://example.com", account: "josh",
            field: field, action: action, createdAt: Date(timeIntervalSince1970: 0))
        let record = ApprovalCloudRecords.request(request)
        record["oneTimeValue"] = Data(repeating: 0xff, count: 32)
        record["notificationTitle"] = "Stale title"
        record.encryptedValues["notificationBody"] = "Stale body"

        let fields = try #require(ApprovalCloudRecords.signedFields(from: record))
        #expect(fields.notificationTitle == "Test agent wants your \(field.rawValue)")
        #expect(fields.notificationBody == "https://example.com · josh")
        #expect(fields.notificationSubtitle == action.rawValue)

        // Fixed wire vector: the visible values occupy the signed UTF-8 components.
        let fieldHex: String
        switch field {
        case .password: fieldHex = "0000000870617373776f7264"
        case .username: fieldHex = "00000008757365726e616d65"
        case .totp: fieldHex = "00000004746f7470"
        }
        let actionHex = action == .fill ? "0000000466696c6c" : "0000000761637175697265"
        let expectedHex = [
            "4167656e744b657972696e672e617070726f76616c2e763100",
            "00000000000000000000000000000001",
            "0000000a54657374206167656e74",
            "0000001368747470733a2f2f6578616d706c652e636f6d",
            "000000046a6f7368",
            fieldHex, actionHex,
            "00000020" + String(repeating: "ff", count: 32),
            "0000000000000258",
            "00000007617070726f7665"
        ].joined()
        #expect(fields.canonicalBytes(for: .approve).map { String(format: "%02x", $0) }.joined() == expectedHex)
    }
}
