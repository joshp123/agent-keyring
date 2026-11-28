// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Every Mac page in each state, with the longest words each will hold, for
// the cut-off check (PageGallery). Made-up names and example sites only.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

@MainActor
enum MacGallery {
    private static let site = "accounts.longcompany-example.co.uk"
    private static let account = "firstname.lastname.for.work@example.com"
    private static let agent = "Research Assistant for Bookkeeping"
    private static let reason = "You asked me to download October’s invoice from the billing page and attach it to the expenses report, then file it in the shared bookkeeping folder."
    /// An iPhone reports only "iPhone"; a computer's name is his to choose, so it holds the long name.
    private static let phone = "iPhone"
    private static let computer = "Research Team Linux Build Server"
    private static let reply = "Use the invoice already in my Downloads folder instead, it is the same one, then carry on with the report."
    private static let command = DeviceSheetCopy.enrolCommand("HCFG-X72D-59SP-1DF8-3G7S-MFBE-44")

    static var entries: [KeyringGalleryEntry] {
        thisMac + firstRun + sheets + cards
    }

    // MARK: Before first run, on a Mac with no Touch ID

    private static var thisMac: [KeyringGalleryEntry] {
        let failure = MessageCopy.keysNotMade(NSError(domain: "com.apple.LocalAuthentication", code: -1000,
            userInfo: [NSLocalizedDescriptionKey: "Failed to get the biometric database hash for this Mac’s keys."]))
        return [
            .init("this-mac-ask", .macWindow) { ThisMacPage(.askHowUsed, actions: .init()) },
            .init("this-mac-for-agents", .macWindow) { ThisMacPage(.forAgents, actions: .init()) },
            .init("this-mac-personal", .macWindow) { ThisMacPage(.personalMac(failure: nil), actions: .init()) },
            .init("this-mac-personal-failed", .macWindow) { ThisMacPage(.personalMac(failure: failure), actions: .init()) },
            .init("this-mac-no-secure-enclave", .macWindow) { ThisMacPage(.noSecureEnclave, actions: .init()) },
            .init("this-mac-keys-failed", .macWindow) { ThisMacPage(.keysFailed(failure), actions: .init()) },
        ]
    }

    // MARK: First run

    private static func practice(_ state: MacPracticePageState, _ approver: MacApproverState = .ready,
                                 mode: MacApprovalMode = .biometricOrCompanion) -> MacPracticePage {
        MacPracticePage(state, approver: approver, mode: mode, actions: .init())
    }

    private static let agentNote = FirstRunCopy.agentNote(appPath: "/Applications/Agent Keyring.app")

    private static let sampleReviewRows: [MacReviewPasswordRow] = [
        .init(id: UUID(), displayName: "Cloudflare", host: "dash.cloudflare.com", account: "alex@example.com", categoryLabel: SelectiveImportCopy.categoryCodingTitle, isSelected: true, isSensitive: false),
        .init(id: UUID(), displayName: "OpenAI", host: "platform.openai.com", account: "alex@example.com", categoryLabel: SelectiveImportCopy.categoryAITitle, isSelected: true, isSensitive: false),
        .init(id: UUID(), displayName: "Claude", host: "console.anthropic.com", account: "alex@example.com", categoryLabel: SelectiveImportCopy.categoryAITitle, isSelected: true, isSensitive: false),
        .init(id: UUID(), displayName: "AWS", host: "console.aws.amazon.com", account: "alex@example.com", categoryLabel: SelectiveImportCopy.categoryCodingTitle, isSelected: true, isSensitive: false),
        .init(id: UUID(), displayName: "GitHub", host: "github.com", account: "alex-dev", categoryLabel: SelectiveImportCopy.categoryCodingTitle, isSelected: true, isSensitive: false),
    ]

    private static var firstRun: [KeyringGalleryEntry] { [
        .init("first-run-welcome", .macWindow) { MacWelcomePage(mode: .biometricOrCompanion) {} },
        .init("first-run-welcome-mac-password", .macWindow) { MacWelcomePage(mode: .devicePassword) {} },
        .init("first-run-welcome-iphone-found", .macWindow) { MacWelcomePage(mode: .devicePassword, iPhone: .found(name: "iPhone")) {} },
        .init("first-run-welcome-iphone-asking", .macWindow) { MacWelcomePage(iPhone: .asking(name: "iPhone")) {} },
        .init("first-run-welcome-iphone-not-added", .macWindow) { MacWelcomePage(iPhone: .notAdded(name: "iPhone")) {} },
        .init("first-run-welcome-iphone-joined", .macWindow) { MacWelcomePage(iPhone: .joined(name: "iPhone")) {} },
        .init("first-run-practice-not-sent", .macWindow) { practice(.notSent) },
        .init("first-run-practice-waiting", .macWindow) { practice(.waiting) },
        .init("first-run-practice-approved", .macWindow) { practice(.approved) },
        .init("first-run-practice-denied", .macWindow) { practice(.denied(reply: "")) },
        .init("first-run-practice-denied-with-reply", .macWindow) { practice(.denied(reply: reply)) },
        .init("first-run-practice-lid-closed", .macWindow) { practice(.notSent, .lidClosed) },
        .init("first-run-practice-needs-fingerprint", .macWindow) { practice(.notSent, .needsFingerprint) },
        .init("first-run-practice-touch-id-missing", .macWindow) { practice(.notSent, .touchIDMissing) },
        .init("first-run-practice-mac-password", .macWindow) { practice(.notSent, mode: .devicePassword) },
        .init("first-run-privacy", .macWindow) { MacPrivacyPage() },
        .init("first-run-import-choose", .macWindow) { MacSelectiveImportPage(.init(step: .choose)) },
        .init("first-run-import-pick-few", .macWindow) { MacSelectiveImportPage(.init(step: .pickFew(guideStep: 1))) },
        .init("first-run-import-categories", .macWindow) { MacSelectiveImportPage(.init(step: .pickCategories)) },
        .init("first-run-import-export-bridge", .macWindow) {
            MacSelectiveImportPage(.init(step: .exportBridge(
                selectedCategoryTitles: [SelectiveImportCopy.categoryCodingTitle, SelectiveImportCopy.categoryAITitle],
                isAllPasswords: false
            )))
        },
        .init("first-run-import-review-filtered", .macWindow) {
            MacSelectiveImportPage(.init(step: .review(
                items: Self.sampleReviewRows,
                isCategoryMode: true,
                sensitiveExcludedCount: 0,
                sensitiveExcludedExamples: [],
                isSaving: false
            )))
        },
        .init("first-run-import-review-all", .macWindow) {
            MacSelectiveImportPage(.init(step: .review(
                items: Self.sampleReviewRows
                    + (0..<486).map { i in
                        MacReviewPasswordRow(id: UUID(), displayName: "Site \(i)", host: "site\(i).example", account: "", categoryLabel: nil, isSelected: false, isSensitive: false)
                    }
                    + (0..<29).map { i in
                        MacReviewPasswordRow(id: UUID(), displayName: "Bank \(i)", host: "bank\(i).example", account: "", categoryLabel: SelectiveImportCopy.categorySensitiveLabel, isSelected: false, isSensitive: true)
                    },
                isCategoryMode: false,
                sensitiveExcludedCount: 29,
                sensitiveExcludedExamples: ["1Password (2)", "American Express Cards", "Wise", "HMRC", "Monzo"],
                isSaving: false
            )))
        },
        .init("first-run-import-receipt", .macWindow) {
            MacSelectiveImportPage(.init(step: .receipt(.init(
                filteredCount: 412,
                savedCount: 6,
                notSavedCount: 406,
                savedSites: [
                    .init(displayName: "Cloudflare", host: "cloudflare.com"),
                    .init(displayName: "OpenAI", host: "openai.com"),
                    .init(displayName: "Claude", host: "claude.ai"),
                    .init(displayName: "GitHub", host: "github.com"),
                    .init(displayName: "AWS", host: "aws.amazon.com"),
                    .init(displayName: "Vercel", host: "vercel.com"),
                ]
            ))))
        },
        .init("add-password-sheet", .macPanel(width: MacAddPasswordSheet.width)) {
            MacAddPasswordSheet(onSave: { _, _, _, _, _ in }, onCancel: {})
        },
        .init("first-run-import-syncing", .macWindow) {
            MacSelectiveImportPage(.init(step: .syncingFromDevice(from: phone), status: .waiting(FirstRunCopy.copying), isBusy: true))
        },
        .init("allow-export-sheet", .macPanel(width: MacAllowExportSheet.width)) { MacAllowExportSheet(openSettings: {}, cancel: {}) },
        .init("first-run-connect-agent", .macWindow) { MacConnectAgentPage(.notTried, agentNote: agentNote, actions: .init()) },
        .init("first-run-connect-agent-worked", .macWindow) { MacConnectAgentPage(.worked(agent: agent), agentNote: agentNote, actions: .init()) },
        .init("first-run-connect-agent-denied", .macWindow) { MacConnectAgentPage(.denied(agent: agent), agentNote: agentNote, actions: .init()) },
        .init("first-run-ready", .macWindow) { MacReadyPage(copied: .passwords(1_547), devices: .init(), actions: .init()) },
        .init("first-run-ready-test-password-only", .macWindow) { MacReadyPage(copied: .testPasswordOnly, devices: .init(), actions: .init()) },
        .init("first-run-ready-all-added", .macWindow) {
            MacReadyPage(copied: .passwords(1), devices: .init(iPhone: phone, watch: "Apple Watch",
                                                               computers: [computer, "Research Team Mac mini"]), actions: .init())
        },
        .init("agent-note-sheet", .macPanel(width: MacDeviceSheet.width)) { MacAgentNoteSheet(agentNote: agentNote) {} },
    ] }

    // MARK: Adding an iPhone or a computer

    private static func iPhone(_ state: MacAddIPhoneSheetState) -> MacAddIPhoneSheet { MacAddIPhoneSheet(state, checkAgain: {}, close: {}) }
    private static func computer(_ state: MacAddComputerSheetState) -> MacAddComputerSheet { MacAddComputerSheet(state, actions: .init()) }

    private static var sheets: [KeyringGalleryEntry] {
        let width = KeyringGalleryEntryKind.macPanel(width: MacDeviceSheet.width)
        return [
            .init("add-iphone-no-icloud", width) { iPhone(.noICloud) },
            .init("add-iphone-problem", width) { iPhone(.problem(MessageCopy.noKeysYet)) },
            .init("add-iphone-waiting", width) { iPhone(.waiting(notAdded: nil)) },
            .init("add-iphone-not-added", width) { iPhone(.waiting(notAdded: phone)) },
            .init("add-iphone-join-asked", width) { iPhone(.joinAsked(name: phone)) },
            .init("add-iphone-copying", width) { iPhone(.copying(name: phone, done: 1_250, total: 1_547)) },
            .init("add-iphone-stopped", width) {
                iPhone(.stopped(name: phone, done: 1_250, total: 1_547, reason: "This Mac couldn’t save the copies."))
            },
            .init("add-iphone-added", width) { iPhone(.added(name: phone)) },
            .init("add-computer-starting", width) { computer(.starting) },
            .init("add-computer-invite", width) { computer(.invite(command: command, until: "14:32")) },
            .init("add-computer-join-asked", width) { computer(.joinAsked(name: computer)) },
            .init("add-computer-added", width) { computer(.added(name: computer)) },
            .init("add-computer-not-added", width) { computer(.notAdded(name: computer)) },
            .init("add-computer-expired", width) { computer(.expired) },
            .init("add-computer-withdrawn", width) { computer(.withdrawn) },
        ]
    }

    // MARK: The card beside the window, and the question panel

    private static func request(_ state: AccessRequestState) -> AccessRequest {
        AccessRequest(id: "r", login: RequestedLogin(site: site, account: account),
                      agent: RequestingAgent(name: agent, machine: "", address: "", project: "bookkeeping", isLocal: true),
                      access: .login, agentReason: reason, askedAt: .now, state: state)
    }

    private static func join(_ lead: String, _ name: String, _ body: String, replies: Bool, approved: String = "",
                             state: AccessRequestState = .waitingForYou(until: .distantFuture)) -> AccessRequest {
        AccessRequest(id: "j", login: RequestedLogin(site: name, account: ""),
                      agent: RequestingAgent(name: name, machine: name, address: ""),
                      access: .setUp(lead: lead, detail: body, footer: "", denied: SetupCopy.notAdded(name), replies: replies, approved: approved),
                      agentReason: "", askedAt: .now, state: state)
    }

    private static var cards: [KeyringGalleryEntry] {
        let width = KeyringGalleryEntryKind.macPanel(width: MacApprovalPanelView.width)
        let waiting = AccessRequestState.waitingForYou(until: .distantFuture)
        let practice = AccessRequest.practiceAccessRequest(id: "p", state: waiting)
        return [
            .init("card-request", width) { ReviewRendering.panel(request(waiting)) },
            .init("card-request-from-another-computer", width) {
                var remote = request(waiting)
                remote.agent = RequestingAgent(name: agent, machine: computer, address: "", isLocal: false)
                return ReviewRendering.panel(remote)
            },
            .init("card-request-typed-reply", width) { ReviewRendering.panel(request(waiting), reply: reply) },
            .init("card-request-waiting-for-touch-id", width) { ReviewRendering.panel(request(waiting), waiting: true) },
            .init("card-request-lid-closed", width) { ReviewRendering.panel(request(waiting), lidClosed: true, approvesElsewhere: true) },
            .init("card-request-touch-id-missing", width) { ReviewRendering.panel(request(waiting), touchIDMissing: true) },
            .init("card-request-touch-id-missing-elsewhere", width) { ReviewRendering.panel(request(waiting), touchIDMissing: true, approvesElsewhere: true) },
            .init("card-request-mac-password", width) { ReviewRendering.panel(request(waiting), approver: .password) },
            .init("card-request-waiting-for-mac-password", width) { ReviewRendering.panel(request(waiting), waiting: true, approver: .password) },
            .init("card-request-watch", width) { ReviewRendering.panel(request(waiting), approver: .watch) },
            .init("card-request-approved", width) { ReviewRendering.panel(request(.approved(by: .mac, until: .now.addingTimeInterval(1_800)))) },
            .init("card-request-denied-with-reply", width) { ReviewRendering.panel(request(.denied(by: .mac, reply: reply, askAgainAfter: nil))) },
            .init("card-request-no-answer", width) { ReviewRendering.panel(request(.unanswered)) },
            .init("card-practice", width) { ReviewRendering.panel(practice) },
            .init("card-practice-approved", width) { ReviewRendering.panel(.practiceAccessRequest(id: "p", state: .approved(by: .mac, until: .now))) },
            .init("card-add-iphone", width) { ReviewRendering.panel(join(SetupCopy.addIPhoneLead, phone, SetupCopy.addIPhoneBody, replies: false)) },
            .init("card-add-iphone-copying", width) {
                ReviewRendering.panel(join(SetupCopy.addIPhoneLead, phone, SetupCopy.addIPhoneBody, replies: false,
                                           approved: SetupCopy.copyingTo(done: 1_250, total: 1_547), state: .approved(by: .mac, until: .now)))
            },
            .init("card-add-watch", width) {
                ReviewRendering.panel(join(SetupCopy.addWatchLead, "Apple Watch", SetupCopy.addWatchBody, replies: false))
            },
            .init("card-add-computer", width) { ReviewRendering.panel(join(SetupCopy.addComputerLead, computer, SetupCopy.addComputerBody, replies: true)) },
            .init("card-add-computer-denied", width) {
                ReviewRendering.panel(join(SetupCopy.addComputerLead, computer, SetupCopy.addComputerBody, replies: true,
                                           state: .denied(by: .mac, reply: nil, askAgainAfter: nil)))
            },
            .init("question-automatic-copies", width) {
                MacQuestionPanelView(lead: SetupCopy.automaticCopiesLead, title: SetupCopy.automaticCopiesTitle, message: SetupCopy.automaticCopiesBody,
                                     approval: OwnerApproval(action: SetupCopy.allow.lowercased(), reason: SetupCopy.automaticCopiesReason,
                                                             authenticate: { [world = SandboxWorld()] in SandboxOwnerAuthentication(world) },
                                                             finish: { _ in }), approverInRender: .touchID)
            },
        ]
    }
}
#endif
