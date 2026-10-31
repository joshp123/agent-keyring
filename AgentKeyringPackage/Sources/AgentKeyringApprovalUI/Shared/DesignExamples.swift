// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Made-up requests for previews and design screenshots. No real accounts:
// the repository is public.

import Foundation

public enum DesignExamples {
    public static let macMini = (name: "Mac mini", address: "100.101.4.7")
    public static let macBook = (name: "MacBook Pro", address: "100.88.12.40")

    public static func githubSignIn(now: Date = .now, state: AccessRequestState? = nil) -> AccessRequest {
        AccessRequest(
            id: "lease-github",
            login: RequestedLogin(site: "github.com", account: "josh@example.com"),
            agent: RequestingAgent(name: "Codex", machine: macMini.name, address: macMini.address,
                folder: "~/code/invoices"),
            access: .signIn,
            agentReason: "You asked me to download October's invoice from GitHub billing and check the seat count.",
            askedAt: now.addingTimeInterval(-48),
            state: state ?? .waitingForYou(until: now.addingTimeInterval(252)),
            events: [
                AccessRequestEvent(now.addingTimeInterval(-48), "Codex asked on Mac mini"),
                AccessRequestEvent(now.addingTimeInterval(-46), "Shown on your Mac"),
                AccessRequestEvent(now.addingTimeInterval(-6), "Sent to this iPhone after 2 minutes"),
            ]
        )
    }

    /// A request from an agent on the Mac showing it, not through the relay.
    public static func localSignIn(now: Date = .now) -> AccessRequest {
        AccessRequest(
            id: "lease-local",
            login: RequestedLogin(site: "kpn.com", account: "josh@example.com"),
            agent: RequestingAgent(name: "Claude Code", machine: macBook.name, address: "", folder: "~/Documents/roaming",
                isLocal: true),
            access: .signIn,
            agentReason: "Downloading September's roaming charges so you can dispute them.",
            askedAt: now.addingTimeInterval(-12),
            state: .waitingForYou(until: now.addingTimeInterval(588)))
    }

    public static func ghProgram(now: Date = .now, state: AccessRequestState? = nil) -> AccessRequest {
        AccessRequest(
            id: "lease-gh-cli",
            login: RequestedLogin(site: "github.com", account: "deploy-bot"),
            agent: RequestingAgent(name: "Claude Code", machine: macBook.name, address: macBook.address,
                folder: "~/code/agent-keyring"),
            access: .program("gh auth login --with-token"),
            agentReason: "Signing the gh CLI in so I can open the release pull request you asked for.",
            askedAt: now.addingTimeInterval(-20),
            state: state ?? .waitingForYou(until: now.addingTimeInterval(280))
        )
    }

    public static func agentProcessRead(now: Date = .now) -> AccessRequest {
        AccessRequest(
            id: "lease-read",
            login: RequestedLogin(site: "router.home.arpa", account: "admin"),
            agent: RequestingAgent(name: "Codex", machine: macBook.name, address: macBook.address,
                folder: "~/code/nix"),
            access: .agentProcess,
            agentReason: "The router's admin page opens in my own browser, which Agent Keyring can't fill. Checking the WAN address you asked about.",
            askedAt: now.addingTimeInterval(-15),
            state: .waitingForYou(until: now.addingTimeInterval(585))
        )
    }

    public static let setupCode = "7F3A 91C2 0B4E D8A5 6C17 E902 44BB 13F0"

    public static func machineEnrolment(now: Date = .now) -> DeviceEnrolment {
        DeviceEnrolment(id: "enrol-build", kind: .machine, name: "build server", tailnetNode: "mini-server-1",
            code: setupCode, askedAt: now.addingTimeInterval(-20))
    }

    public static func iPhoneEnrolment(now: Date = .now) -> DeviceEnrolment {
        DeviceEnrolment(id: "enrol-iphone", kind: .approver, name: "Josh's iPhone", tailnetNode: "",
            code: "A04C 7E19 33D2 9B60 0F8E C51A 6D27 E4B3", askedAt: now.addingTimeInterval(-8))
    }

    /// Everything that happened recently, newest first, in a mix of outcomes.
    public static func history(now: Date = .now) -> [AccessRequest] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            AccessRequest(
                id: "h-ns", login: RequestedLogin(site: "ns.nl", account: "josh@example.com"),
                agent: RequestingAgent(name: "Claude Code", machine: macBook.name, address: macBook.address,
                    folder: "~/Documents/travel"),
                access: .signIn,
                agentReason: "Checking whether the €25 charge on your October statement was a missed check-out.",
                askedAt: ago(14), state: .approved(by: .iPhone, until: ago(-16)),
                events: [
                    AccessRequestEvent(ago(14), "Claude Code asked on MacBook Pro"),
                    AccessRequestEvent(ago(12), "Sent to this iPhone after 2 minutes"),
                    AccessRequestEvent(ago(11.5), "You approved with Face ID"),
                    AccessRequestEvent(ago(11.4), "Signed in: username and password"),
                    AccessRequestEvent(ago(10.8), "Filled the one-time code"),
                ]),
            AccessRequest(
                id: "h-kpn", login: RequestedLogin(site: "kpn.com", account: "josh@example.com"),
                agent: RequestingAgent(name: "Codex", machine: macMini.name, address: macMini.address,
                    folder: "~/Documents/roaming"),
                access: .signIn,
                agentReason: "Downloading the roaming charges from September so you can dispute them.",
                askedAt: ago(52), state: .released(at: ago(44)),
                events: [
                    AccessRequestEvent(ago(52), "Codex asked on Mac mini"),
                    AccessRequestEvent(ago(51.8), "You approved with Touch ID on your Mac"),
                    AccessRequestEvent(ago(51.7), "Signed in: username and password"),
                    AccessRequestEvent(ago(44), "Codex said it was done"),
                ]),
            AccessRequest(
                id: "h-instagram", login: RequestedLogin(site: "instagram.com", account: "josh.photos"),
                agent: RequestingAgent(name: "Codex", machine: macBook.name, address: macBook.address),
                access: .signIn,
                agentReason: "Comparing reach on your last twelve posts before you publish the deer series.",
                askedAt: ago(12), state: .denied(by: .iPhone, reply: "You're already signed in. Use the open tab.",
                    askAgainAfter: ago(-18)),
                events: [
                    AccessRequestEvent(ago(12), "Codex asked on MacBook Pro"),
                    AccessRequestEvent(ago(10), "Sent to this iPhone after 2 minutes"),
                    AccessRequestEvent(ago(9), "You denied and replied"),
                ]),
            AccessRequest(
                id: "h-example", login: RequestedLogin(site: "example.com", account: "test"),
                agent: RequestingAgent(name: "Claude Code", machine: macBook.name, address: macBook.address),
                access: .signIn, agentReason: "Testing the sign-in flow.",
                askedAt: ago(130), state: .released(at: ago(129)),
                events: [AccessRequestEvent(ago(130), "Approved by rule")]),
            AccessRequest(
                id: "h-gmail", login: RequestedLogin(site: "accounts.google.com", account: "josh@example.com"),
                agent: RequestingAgent(name: "pi", machine: macMini.name, address: macMini.address),
                access: .signIn, agentReason: "Reading your inbox to find the booking reference.",
                askedAt: ago(200), state: .blockedByRule,
                events: [AccessRequestEvent(ago(200), "Blocked by rule. You weren't asked.")]),
            AccessRequest(
                id: "h-pacer", login: RequestedLogin(site: "pacer.uscourts.gov", account: "josh"),
                agent: RequestingAgent(name: "Codex", machine: macMini.name, address: macMini.address),
                access: .signIn, agentReason: "Checking whether the withdrawal has been docketed.",
                askedAt: ago(60 * 20), state: .unanswered,
                events: [AccessRequestEvent(ago(60 * 20), "Nobody answered in 5 minutes")]),
            AccessRequest(
                id: "h-figma", login: RequestedLogin(site: "figma.com", account: "josh@example.com"),
                agent: RequestingAgent(name: "Claude Code", machine: macBook.name, address: macBook.address),
                access: .signIn, agentReason: "Exporting the logo frames you asked for.",
                askedAt: ago(60 * 21), state: .cancelled,
                events: [AccessRequestEvent(ago(60 * 21), "Claude Code asked, then found it was already signed in")]),
            AccessRequest(
                id: "h-hilton", login: RequestedLogin(site: "hilton.com", account: "josh@example.com"),
                agent: RequestingAgent(name: "Claude Code", machine: macBook.name, address: macBook.address),
                access: .signIn, agentReason: "Finding the receipt for your Lisbon stay.",
                askedAt: ago(60 * 22), state: .expired(at: ago(60 * 22 - 30))),
        ]
    }
}
