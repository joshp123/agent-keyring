// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Every part, with the longest words it will hold, at the smallest size it
// will get. The checks host each entry and fail on any cut-off; the
// renderer draws each one to a file. Pages add their own entries the same
// way (see docs/design/page-parts.md). Sample data only: example sites and
// made-up names.

import SwiftUI

public struct KeyringGalleryEntry: Identifiable {
    public enum Kind: Sendable, Hashable {
        /// The Mac setup window, 760 by 560.
        case macWindow
        /// A floating Mac panel or sheet of this width, as tall as it needs.
        case macPanel(width: CGFloat)
        /// iPhone, 375 points wide, scrolling.
        case phone
        /// Apple Watch 41 mm, scrolling.
        case watch
    }

    public let id: String
    public let kind: Kind
    public let view: AnyView

    public init(_ id: String, _ kind: Kind, @ViewBuilder view: () -> some View) {
        self.id = id
        self.kind = kind
        self.view = AnyView(view())
    }
}

/// Long words for the samples, longer than any real one the copy holds.
enum Longest {
    static let site = "accounts.longcompany-example.co.uk"
    static let account = "firstname.lastname.for.work@example.com"
    static let reason = "You asked me to download October’s invoice from the billing page and attach it to the expenses report, then file it in the shared bookkeeping folder."
    static let macName = "Research Team MacBook Pro"
    static let agent = "Research Assistant for Bookkeeping"
    static let waitedTooLong = "No passwords have arrived yet. In Select a Destination, make sure you chose Agent Keyring with the blue keyhole (not an earlier version), or check that Agent Keyring is turned on in AutoFill Settings."
    static let command = "agent-keyring enrol --name \"$(hostname -s)\" --invite \"agentkeyring://join?invite=Cg4yLjEuM2E5ZjFOGlx7Q2xNwPq8rT\""
}

@MainActor
public enum KeyringGallery {
    private static func none() {}

    public static var parts: [KeyringGalleryEntry] {
        #if os(macOS)
        mac
        #elseif os(iOS)
        phone
        #else
        watch
        #endif
    }

    #if os(macOS)
    private static let steps = [KeyringSetupStep("Try a request", .done), KeyringSetupStep("Copy passwords", .current),
                                KeyringSetupStep("Connect an agent", .upcoming), KeyringSetupStep("Ready", .upcoming)]

    private static var mac: [KeyringGalleryEntry] { [
        .init("setup-window-practice", .macWindow) {
            KeyringSetupWindow(heading: "Setup on this Mac", steps: steps.enumerated().map { KeyringSetupStep($1.title, $0 == 0 ? .current : .upcoming) }) {
                KeyringPage(step: (1, 4), title: "Try a password request",
                            sentence: "See how an AI agent asks for a password. This practice request doesn’t share any passwords.",
                            primary: .advance("Continue", perform: none), secondary: .plain("Back", perform: none)) {
                    KeyringHint(symbol: "hand.tap", "Click **Send Practice Request** to open a sample approval card beside this window.")
                    KeyringButton(.advance("Send Practice Request", perform: none))
                    KeyringConfirmation("You denied it and replied", detail: "A real agent would get your reply: “Use the invoice in my Downloads folder instead, it is the same one.”", tone: .denied)
                }
            }
        },
        .init("setup-window-copy-taking-long", .macWindow) {
            KeyringSetupWindow(heading: "Setup on this Mac", steps: steps, mascot: .waiting) {
                KeyringPage(step: (2, 4), title: "Copy your passwords",
                            sentence: "Click Open Passwords below, then step through this 5-part guide at your own pace. Copying deletes nothing from Passwords.",
                            status: .takingLong(Longest.waitedTooLong),
                            primary: .advance("Open Passwords", perform: none), secondary: .plain("Back", perform: none),
                            aside: .link("Use Test Password Only", perform: none)) {
                    KeyringStepRow(4, "In **Select a Destination**, choose **Agent Keyring** (blue keyhole), then click **Continue**.")
                }
            }
        },
        .init("setup-window-connect-agent", .macWindow) {
            KeyringSetupWindow(heading: "Setup on this Mac", steps: steps.enumerated().map { KeyringSetupStep($1.title, $0 < 2 ? .done : $0 == 2 ? .current : .upcoming) }) {
                KeyringPage(step: (3, 4), title: "Connect an agent",
                            sentence: "Give your AI agent this instruction so it knows how to ask Agent Keyring for passwords and two-factor codes.",
                            primary: .advance("Continue", perform: none), secondary: .plain("Back", perform: none), aside: .link("Skip the Test", perform: none)) {
                    KeyringCopyBlock("1. Add to your agent’s instructions (AGENTS.md or CLAUDE.md)",
                                     text: "When a task needs a website password or a two-factor code, use Agent Keyring. To learn how, run \"/Applications/Agent Keyring.app/Contents/Helpers/agent-keyring\" skill")
                    KeyringCopyBlock("2. Try it: send this to an agent", text: "Use Agent Keyring to get the test password for example.com.")
                    KeyringHint(symbol: "rectangle.on.rectangle", "**What to expect:** When your agent asks for a password, an approval card pops up beside your active window.", tone: .plain)
                }
            }
        },
        .init("setup-window-ready", .macWindow) {
            KeyringSetupWindow(heading: "Setup on this Mac", steps: steps.map { KeyringSetupStep($0.title, $0.title == "Ready" ? .current : .done) }, mascot: .approved) {
                KeyringPage(step: (4, 4), title: "Agent Keyring is ready on this Mac", primary: .advance("Show Passwords", perform: none)) {
                    KeyringConfirmation("547 passwords copied.", detail: "Click the keyhole in your menu bar any time.")
                    KeyringRowGroup {
                        KeyringDeviceRow(symbol: "iphone", name: "iPhone", detail: "Approve password requests with Face ID anywhere.") { KeyringButton(.plain("Add…", perform: none)) }
                        KeyringDeviceRow(symbol: "applewatch", name: "Apple Watch", detail: "Approve with one tap on your wrist. Added from your iPhone.") { KeyringButton(.plain("Added on iPhone", perform: none)) }
                        KeyringDeviceRow(symbol: "server.rack", name: "Other Computers", detail: "Let agents on a Linux server or another Mac ask too.") { KeyringButton(.plain("Add…", perform: none)) }
                    }
                }
            }
        },
        .init("approval-card-request", .macPanel(width: KeyringSize.macCard)) {
            KeyringApprovalCard(lead: "\(Longest.agent) on \(Longest.macName) wants", subject: Longest.site, detail: Longest.account,
                                reason: Longest.reason, reply: .constant(""), replyPrompt: "What should the agent do instead?",
                                approve: .approve("Click to approve with Touch ID", perform: none), deny: .deny("Deny", perform: none),
                                footer: "If you approve, the agent can use it until 14:32.", header: "Agent Keyring")
                .padding(KeyringSpace.s5)
        },
        .init("approval-card-join", .macPanel(width: KeyringSize.macCard)) {
            KeyringApprovalCard(lead: "Add this iPhone to Agent Keyring?", subject: "\(Longest.macName) iPhone",
                                explanation: "It gets its own encrypted copy of your passwords, locked in its Secure Enclave, and can approve password requests with Face ID.",
                                approve: .approve("Click to approve with Touch ID", perform: none), deny: .deny("Deny", perform: none),
                                footer: "Copying your passwords to it: 312 of 547. You can remove it later in Devices.", header: "Agent Keyring")
                .padding(KeyringSpace.s5)
        },
        // The green button Josh found cut off at "Click here, then touch the sen…".
        .init("approval-card-send-changes", .macPanel(width: KeyringSize.macCard)) {
            KeyringApprovalCard(lead: "Agent Keyring", subject: "Send 15 password changes to your other devices?",
                                explanation: "You copied 12 new, 2 changed, and 1 removed password from Passwords. Confirm with Touch ID to update your iPhone and other computers. If you choose Not Now, they keep your previous list until you update them.",
                                approve: .approve("Click to approve with Touch ID", perform: none), deny: .plain("Not Now", perform: none))
                .padding(KeyringSpace.s5)
        },
        .init("add-iphone-sheet", .macPanel(width: 460)) {
            KeyringPage(title: "Add your iPhone",
                        sentence: "Approve password requests from your AI agents with Face ID anywhere. Each password is end-to-end encrypted for your iPhone’s Secure Enclave and signed against tampering. Both devices need Tailscale turned on.",
                        status: .waiting("Waiting for your iPhone…"),
                        primary: .plain("Do This Later", perform: none), aside: .link("Having trouble?", perform: none)) {
                KeyringQRBlock(url: "https://testflight.apple.com/join/EXAMPLE1", steps: [
                    "Scan to get TestFlight from the App Store, then open Agent Keyring inside TestFlight.",
                    "Make sure Tailscale is on for both devices, then tap **Connect** on your iPhone.",
                    "Approve your iPhone beside this window with Touch ID."])
            }
        },
        .init("add-computer-sheet", .macPanel(width: 460)) {
            KeyringPage(title: "Add another computer",
                        sentence: "Send this note to an agent on a Linux server or another Mac. The invite works once, for 10 minutes, and you approve it beside this window with Touch ID.",
                        primary: .plain("Cancel", perform: none)) {
                KeyringCopyBlock(text: Longest.command, monospaced: true, more: [.plain("Copy Prompt for Agent", perform: none)])
            }
        },
        .init("status-lines-and-hints", .macPanel(width: KeyringSize.measure)) {
            VStack(alignment: .leading, spacing: KeyringSpace.s4) {
                KeyringStatusLine(.waiting("Looking for your Mac via iCloud…"))
                KeyringStatusLine(.takingLong(Longest.waitedTooLong))
                KeyringStatusLine(.done("Claude Code got the password. You’re connected."))
                KeyringStatusLine(.problem("Couldn’t copy your passwords. The Passwords app closed before it finished. Try again."))
                KeyringHint(symbol: "moon.fill", "Vibe coding late at night? If Sleep or Driving Focus is on, iOS silences notifications unless Agent Keyring is allowed in Settings > Focus.", tone: .focus)
                KeyringHint(symbol: "exclamationmark.circle.fill", title: "Not showing up on your Watch?", "Check that your Watch is unlocked, has a passcode, and Bluetooth is on. You can cancel and start again any time.", tone: .stalled)
            }
            .padding(KeyringSpace.s5)
        },
        .init("buttons-and-mascot", .macPanel(width: KeyringSize.measure)) {
            VStack(alignment: .leading, spacing: KeyringSpace.s4) {
                HStack(spacing: KeyringSpace.s2) {
                    KeyringButton(.advance("Send Another Practice Request", perform: none))
                    KeyringButton(.plain("Back", perform: none))
                }
                HStack(spacing: KeyringSpace.s2) {
                    KeyringButton(.approve("Approve", perform: none))
                    KeyringButton(.deny("Deny", perform: none))
                    KeyringButton(.link("Agent Keyring isn’t in the list?", perform: none))
                }
                HStack(spacing: KeyringSpace.s3) {
                    ForEach(KeyringMascot.Mood.allCases, id: \.self) { KeyringMascot($0).frame(width: 48, height: 48) }
                }
            }
            .padding(KeyringSpace.s5)
        },
    ] }
    #endif

    #if os(iOS)
    private static var phone: [KeyringGalleryEntry] { [
        .init("page-found-mac", .phone) {
            KeyringPage(step: (1, 3), title: "Continue setup from \(Longest.macName)",
                        sentence: "Connect this iPhone to approve password requests from your AI agents with Face ID.",
                        alignment: .centre, mascot: .curious,
                        primary: .advance("Connect to \(Longest.macName)", perform: none), secondary: .link("Having trouble?", perform: none)) {
                KeyringHint(symbol: "lock.shield", title: "End-to-end encrypted and signed",
                            "Your Mac encrypts a copy of your passwords for this iPhone’s Secure Enclave and signs them against tampering, so nothing in between can read or change them.", tone: .plain)
            }
        },
        .init("page-notifications", .phone) {
            KeyringPage(step: (2, 3), title: "Turn on notifications",
                        sentence: "Password requests from your AI agents arrive as notifications so you can approve or deny them straight from your Lock Screen.",
                        status: .problem("Notifications are turned off for Agent Keyring. Turn them on in Settings so password requests reach your Lock Screen."),
                        primary: .advance("Turn On Notifications", perform: none), secondary: .link("Continue Without Notifications", perform: none)) {
                KeyringRowGroup {
                    KeyringCheckRow("Notifications allowed", isDone: true)
                    KeyringCheckRow("Banners and Lock Screen", isDone: true)
                    KeyringCheckRow("Time Sensitive", isDone: true)
                    KeyringCheckRow("Not in Scheduled Summary", isDone: false, toDo: "In Settings > Notifications > Scheduled Summary, turn off Agent Keyring.")
                }
                KeyringHint(symbol: "moon.fill", "Vibe coding late at night? If Sleep or Driving Focus is on, iOS silences notifications unless Agent Keyring is allowed in Settings > Focus.", tone: .focus)
            }
        },
        .init("page-practice-not-arrived", .phone) {
            KeyringPage(step: (3, 3), title: "Try a practice notification",
                        sentence: "Tap below to send yourself a practice password request. Touch and hold it to try Approve, Deny, or Deny and Explain. No real passwords are shared.",
                        status: .takingLong("Didn’t see the notification? Focus may have silenced it, or notifications may be off."),
                        primary: .advance("Answer It Here", perform: none), secondary: .plain("Try Again", perform: none), aside: .link("Skip for Now", perform: none))
        },
        .init("page-install-watch-app", .phone) {
            KeyringPage(title: "Install Agent Keyring on your Apple Watch",
                        sentence: "Your Apple Watch is paired with this iPhone, but Agent Keyring isn’t installed on it yet.",
                        primary: .advance("Check Again", perform: none), secondary: .link("Do This Later", perform: none)) {
                KeyringSteps(["On this iPhone, open Apple’s **Watch** app.", "In **My Watch**, scroll to **Available Apps**.", "Tap **Install** next to Agent Keyring, then return here."])
            }
        },
        .init("approval-card-home", .phone) {
            KeyringApprovalCard(lead: "\(Longest.agent) on \(Longest.macName) wants", subject: Longest.site, detail: Longest.account, reason: Longest.reason,
                                approve: .approve("Approve", perform: none), deny: .deny("Deny", perform: none), explain: .denyLink("Deny and Explain", perform: none))
                .padding(KeyringSpace.s6)
        },
        .init("deny-and-explain-sheet", .phone) {
            KeyringPage(primary: .deny("Deny and Send", perform: none), secondary: .approveLink("Approve Instead", perform: none)) {
                KeyringRequestHeader(lead: "\(Longest.agent) on \(Longest.macName) wants", subject: Longest.site, detail: Longest.account, reason: Longest.reason)
                KeyringReplyBox(text: .constant(""), prompt: "Tell the agent what to do instead", note: .listening("Listening…")) {
                    KeyringButton(.plain("Stop", perform: none))
                }
            }
        },
        .init("everyday-list", .phone) {
            List {
                Section {
                    ForEach(2...25, id: \.self) { number in
                        KeyringDeviceRow(symbol: "key", name: "site\(number).example", detail: "you@example.com · asked \(number) times", nameFit: .siteName) {
                            KeyringText(number % 3 == 0 ? "Automatic" : "Ask", as: .meta)
                        }
                    }
                } header: {
                    KeyringText("Passwords", as: .sectionName)
                }
            }
        },
        .init("reply-box-microphone", .phone) {
            VStack(spacing: KeyringSpace.s4) {
                KeyringReplyBox(text: .constant("Use the invoice already in Downloads, it’s the same one. Then carry on with the report and don’t log in to the billing page again today."),
                                prompt: "Tell the agent what to do instead",
                                note: .problem("Agent Keyring can’t use the microphone. Turn on Microphone in Settings."),
                                noteAction: .link("Open Settings", perform: none)) {
                    KeyringButton(.plain("Speak", perform: none))
                }
                KeyringReplyBox(text: .constant(""), prompt: "Tell the agent what to do instead",
                                note: .waiting("Getting the speech model from Apple (40%). Type, or wait a moment."))
                KeyringStatusLine(.listening("Listening…"))
            }
            .padding(KeyringSpace.s6)
        },
        .init("devices-and-copy", .phone) {
            VStack(spacing: KeyringSpace.s4) {
                KeyringRowGroup {
                    KeyringDeviceRow(symbol: "iphone", name: "This iPhone", detail: "Face ID") { KeyringButton(.plain("Send Practice Request", perform: none)) }
                    KeyringDeviceRow(symbol: "laptopcomputer", name: Longest.macName, detail: "On your iPhone, waiting for your answer", tone: .waiting)
                }
                KeyringConfirmation("Apple Watch added", detail: "You can now approve password requests with one tap on your wrist.")
                KeyringStatusLine(.waiting("Looking for your Mac via iCloud…"))
            }
            .padding(KeyringSpace.s6)
        },
    ] }
    #endif

    #if os(watchOS)
    private static var watch: [KeyringGalleryEntry] { [
        .init("approval-card-request", .watch) {
            KeyringApprovalCard(lead: "Claude Code on \(Longest.macName)", subject: Longest.site, detail: Longest.account, reason: Longest.reason,
                                approve: .approve("Approve", perform: none), deny: .deny("Deny", perform: none),
                                explain: .explain("Deny and Explain", prompt: "What should the agent do instead?") { _ in })
        },
        .init("page-add-watch", .watch) {
            KeyringPage(title: "Add this Watch?", sentence: "Approve password requests on your wrist.", mascot: .curious,
                        primary: .approve("Add", perform: none))
        },
        .init("page-watch-added", .watch) {
            KeyringPage(title: "Apple Watch added", sentence: "Ready for password requests.", mascot: .approved,
                        primary: .advance("Try Practice", perform: none), secondary: .plain("Done", perform: none))
        },
        .init("page-preparing", .watch) {
            KeyringPage(title: "Set up iPhone first", sentence: "Open Agent Keyring on your iPhone, then tap Add Apple Watch in Devices.",
                        status: .waiting("Waiting for practice request…"), secondary: .plain("Cancel", perform: none))
        },
    ] }
    #endif
}
