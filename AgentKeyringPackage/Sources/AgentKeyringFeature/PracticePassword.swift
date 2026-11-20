// Written by AI on 2026.11.20 by model claude opus 5.5.
//
// The practice password: always there for an agent's first try ("Try it
// now"), even once his real passwords are copied, so the test never touches
// one of his. It lives only in this Mac's app: it is not in his list, not in
// the catalogue, never sent to the relay, and approving it opens nothing.

import AgentKeyringProtocol
import Foundation

public enum PracticePassword {
    public static let id = UUID(uuidString: "6A3F0E2C-5B1D-4C8A-9E7F-0D2B4A6C8E10")!
    public static let site = "practice.example.com"
    static let username = "you@example.com"

    static let candidate = CredentialCandidate(id: id, title: site, username: username,
        origins: ["https://\(site)"], availableFields: [.username, .password])

    static var secret: Agentkeyring_V2_LoginSecret {
        var secret = Agentkeyring_V2_LoginSecret()
        secret.loginID = id.uuidString
        secret.title = site
        secret.sites = ["https://\(site)"]
        secret.username = username
        secret.password = "practice-only"
        return secret
    }

    static func matches(_ terms: [Substring]) -> Bool {
        let text = "practice \(site) \(username) \(id.uuidString)".lowercased()
        return !terms.isEmpty && terms.allSatisfy { text.contains($0) }
    }
}
