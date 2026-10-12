import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Approval record encoding")
struct ApprovalRecordsTests {
    @Test("Canonical v1 encoding has a fixed, language-independent byte vector")
    func canonicalEncoding() throws {
        let fields = ApprovalSignedFields(
            requestID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            agentDisplayLabel: "Test agent", site: "https://example.com", account: "josh", field: .password, action: .fill,
            oneTimeValue: Data([0x00, 0xff]), expiresAt: 600)
        // Each line is one component, in wire order. No JSON, locale, delimiter or key-order dependency.
        let expectedHex = [
            "4167656e744b657972696e672e617070726f76616c2e763100", // AgentKeyring.approval.v1 + NUL
            "00000000000000000000000000000001", // UUID, 16 bytes
            "0000000a54657374206167656e74", // Test agent, 10 bytes
            "0000001368747470733a2f2f6578616d706c652e636f6d", // UTF-8 site, 19 bytes
            "000000046a6f7368", // UTF-8 account, 4 bytes
            "0000000870617373776f7264", // password, 8 bytes
            "0000000466696c6c", // fill, 4 bytes
            "0000000200ff", // nonce, 2 bytes
            "0000000000000258", // Int64: 600 Unix seconds
            "00000007617070726f7665", // approve, 7 bytes
        ].joined()
        #expect(fields.canonicalBytes(for: .approve).map { String(format: "%02x", $0) }.joined() == expectedHex)
        #expect(fields.canonicalBytes(for: .approve) != fields.canonicalBytes(for: .deny))
        #expect(fields.canonicalBytes(for: .deny) != fields.canonicalBytes(for: .blockThisLogin))
    }

    @Test("New requests have independent 256-bit one-time values and round-trip unchanged")
    func requestValues() throws {
        let first = ApprovalRequest(agentDisplayLabel: "Test agent", site: "https://example.com",
            account: "synthetic", field: .password, action: .acquire)
        let second = ApprovalRequest(agentDisplayLabel: first.agentDisplayLabel, site: first.site,
            account: first.account, field: first.field, action: first.action, createdAt: first.createdAt)
        #expect(first.oneTimeValue.count == 32)
        #expect(first.oneTimeValue != second.oneTimeValue)
        #expect(first.id != second.id)
        #expect(try JSONDecoder().decode(ApprovalRequest.self, from: JSONEncoder().encode(first)) == first)
    }

    @Test("Expiry is derived from creation plus ten minutes and floored to Unix seconds")
    func derivedExpiry() {
        for creationSeconds in [0.125, 0.9999, -0.25] {
            let request = ApprovalRequest(agentDisplayLabel: "Test agent", site: "https://example.com",
                account: "synthetic", field: .password, action: .fill,
                createdAt: Date(timeIntervalSince1970: creationSeconds))
            #expect(request.expiresAt == Int64(floor(creationSeconds + 600)))
        }
    }
}
