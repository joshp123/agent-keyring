// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Lease records as the release 2 store writes them, mapped through the real
// adapter (LeaseScreenMapping), for the `lease…` gallery screens. Made-up
// logins; the repository is public.

import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringProtocol
import AgentKeyringScreenBackends
import Foundation

enum LeaseRecords {
    static func requests(now: Date = .now) -> [AccessRequest] {
        let seconds = Int64(now.timeIntervalSince1970)
        var records: [(Agentkeyring_V1_Lease, CredentialCandidate, CredentialLeaseRequester)] = []

        func add(_ site: String, _ account: String, agent: String, folder: String, purpose: Agentkeyring_V1_Purpose,
            state: Agentkeyring_V1_LeaseState, askedSecondsAgo: Int64, reason: String,
            configure: (inout Agentkeyring_V1_Lease) -> Void = { _ in }) {
            let loginID = UUID()
            var lease = Agentkeyring_V1_Lease()
            lease.leaseID = UUID().uuidString
            lease.loginID = loginID.uuidString
            lease.taskRef = "gallery"
            lease.purpose = purpose
            lease.state = state
            lease.reason = reason
            lease.sites = ["https://\(site)/login"]
            lease.recipient.machineLabel = "MacBook Pro"
            lease.recipient.clientLabel = "Local agents"
            lease.requestedAtUnixSeconds = seconds - askedSecondsAgo
            lease.pendingUntilUnixSeconds = seconds - askedSecondsAgo + 600
            configure(&lease)
            let login = CredentialCandidate(id: loginID, title: site, username: account,
                origins: ["https://\(site)"], availableFields: [.username, .password])
            records.append((lease, login, requester(agent, folder: folder)))
        }

        add("github.com", "deploy-bot", agent: "Claude Code", folder: "/Users/josh/code/agent-keyring",
            purpose: .program, state: .pending, askedSecondsAgo: 40,
            reason: "Signing the gh CLI in so I can open the release pull request you asked for.") { lease in
            lease.program.executable = "/opt/homebrew/bin/gh"
            lease.program.arguments = ["auth", "login", "--with-token"]
        }
        add("kpn.com", "josh@example.com", agent: "Codex", folder: "/Users/josh/Documents/roaming",
            purpose: .browserSignIn, state: .pending, askedSecondsAgo: 15,
            reason: "Downloading September's roaming charges so you can dispute them.")
        add("ns.nl", "josh@example.com", agent: "Codex", folder: "/Users/josh/Documents/travel",
            purpose: .browserSignIn, state: .active, askedSecondsAgo: 300,
            reason: "Checking the missed check-out on your October statement.") { lease in
            lease.approvedBy = .mac
            lease.approvedAtUnixSeconds = seconds - 290
            lease.notAfterUnixSeconds = seconds - 290 + 1800
        }
        add("instagram.com", "josh.photos", agent: "Codex", folder: "/Users/josh/Pictures",
            purpose: .browserSignIn, state: .denied, askedSecondsAgo: 720,
            reason: "Comparing reach on your last twelve posts.") { lease in
            lease.reply = "You're already signed in. Use the open tab."
            lease.retryNotBeforeUnixSeconds = seconds + 1080
            lease.endedAtUnixSeconds = seconds - 700
        }
        add("example.com", "test", agent: "Claude Code", folder: "/Users/josh/code/agent-keyring",
            purpose: .browserSignIn, state: .released, askedSecondsAgo: 2400, reason: "Testing the sign-in flow.") { lease in
            lease.approvedBy = .automaticRule
            lease.approvedAtUnixSeconds = seconds - 2400
            lease.endedAtUnixSeconds = seconds - 2340
        }
        add("figma.com", "josh@example.com", agent: "Claude Code", folder: "/Users/josh/code/site",
            purpose: .browserSignIn, state: .revoked, askedSecondsAgo: 3600, reason: "Exporting the logo frames.") { lease in
            lease.approvedBy = .mac
            lease.approvedAtUnixSeconds = seconds - 3590
            lease.endedAtUnixSeconds = seconds - 3000
        }

        return records.map { lease, login, requester in
            LeaseScreenMapping.accessRequest(lease, requester: requester, login: login)
        }
    }

    /// The store keeps this from the requesting process; it has no public
    /// initialiser, so the gallery decodes it the way the store reads it back.
    private static func requester(_ name: String, folder: String) -> CredentialLeaseRequester {
        let json = #"{"name":"\#(name)","workingDirectory":"\#(folder)","machineName":"MacBook Pro"}"#
        return try! JSONDecoder().decode(CredentialLeaseRequester.self, from: Data(json.utf8))
    }
}
