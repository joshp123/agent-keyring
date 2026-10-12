import AgentKeyringFeature
import Foundation
import Testing
@testable import AgentKeyringCLI

@Suite("Mac owner name")
struct MacOwnerTests {
    @Test("Names use the first word, with an empty-name fallback", arguments: [
        ("Alex Example", "Alex"), ("  Renée\tExample \n", "Renée"), ("", "the owner"), (" \t\n", "the owner"),
    ])
    func firstName(fullName: String, expected: String) {
        MacOwner.$fullName.withValue(fullName) {
            #expect(MacOwner.firstName == expected)
            let response = AgentBridgeResponse(id: UUID(), ok: false, error: .authorizationDenied)
            let error = CLIError(response: response, command: .status)
            #expect(error.message == "\(expected) declined the request.")
            #expect(AgentKeyringCLI.helpMessage().contains("\(expected) declined the request."))
            #expect(AccessRulesConfirmationRequired.message.contains("\(expected)'s confirmation"))
        }
    }
}
