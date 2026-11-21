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
    private static let phone = "Research Team iPhone 17 Pro Max"
    private static let computer = "Research Team Linux Build Server"
    private static let reply = "Use the invoice already in my Downloads folder instead, it is the same one, then carry on with the report."
    private static let command = DeviceSheetCopy.enrolCommand("agentkeyring://join?invite=CiBhNWYzZTk4YzQxN2IyMGQ2ZjE5ODBhN2M1ZTNiMjQxMBIRUmVzZWFyY2ggVGVhbSBNYWMaCjEwMC42NC4wLjI")

    static var entries: [KeyringGalleryEntry] {
        firstRun + sheets + cards
    }

    // MARK: First run

    private static func practice(_ state: MacPracticePage.State, _ approver: MacApprover.State = .ready) -> MacPracticePage {
        MacPracticePage(state, approver: approver, actions: .init())
    }

    private static func copy(_ state: MacCopyPage.State, step: Int = 1, earlier: Bool = false, inFirstRun: Bool = true) -> MacCopyPage {
        MacCopyPage(state, guideStep: step, earlierVersion: earlier, inFirstRun: inFirstRun, actions: .init())
    }

    private static let agentNote = FirstRunCopy.agentNote(appPath: "/Applications/Agent Keyring.app")

    private static var firstRun: [KeyringGalleryEntry] { [
        .init("first-run-welcome", .macWindow) { MacWelcomePage {} },
        .init("first-run-practice-not-sent", .macWindow) { practice(.notSent) },
        .init("first-run-practice-waiting", .macWindow) { practice(.waiting) },
        .init("first-run-practice-approved", .macWindow) { practice(.approved) },
        .init("first-run-practice-denied", .macWindow) { practice(.denied(reply: "")) },
        .init("first-run-practice-denied-with-reply", .macWindow) { practice(.denied(reply: reply)) },
        .init("first-run-practice-lid-closed", .macWindow) { practice(.notSent, .lidClosed) },
        .init("first-run-practice-needs-fingerprint", .macWindow) { practice(.notSent, .needsFingerprint) },
        .init("first-run-copy-guide", .macWindow) { copy(.guide) },
        .init("first-run-copy-guide-step-4-earlier-version", .macWindow) { copy(.waiting, step: 4, earlier: true) },
        .init("first-run-copy-taking-long", .macWindow) { copy(.noneArrived, step: 4) },
        .init("first-run-copy-copying", .macWindow) { copy(.copying, step: 5) },
        .init("first-run-copy-copied", .macWindow) { copy(.copied(count: 1_547), step: 5) },
        .init("first-run-copy-failed", .macWindow) {
            copy(.failed("Passwords could not finish sending your passwords. Start the export again in Passwords. Your earlier copy was not changed."), step: 2)
        },
        .init("copy-from-main-window", .macPanel(width: KeyringSize.macWindow.width - KeyringSize.macSidebar)) {
            copy(.waiting, step: 3, inFirstRun: false)
        },
        .init("allow-export-sheet", .macPanel(width: MacAllowExportSheet.width)) { MacAllowExportSheet(openSettings: {}, cancel: {}) },
        .init("first-run-connect-agent", .macWindow) { MacConnectAgentPage(.notTried, agentNote: agentNote, actions: .init()) },
        .init("first-run-connect-agent-worked", .macWindow) { MacConnectAgentPage(.worked(agent: agent), agentNote: agentNote, actions: .init()) },
        .init("first-run-connect-agent-denied", .macWindow) { MacConnectAgentPage(.denied(agent: agent), agentNote: agentNote, actions: .init()) },
        .init("first-run-ready", .macWindow) { MacReadyPage(copied: .passwords(1_547), devices: .init(), actions: .init()) },
        .init("first-run-ready-test-password-only", .macWindow) { MacReadyPage(copied: .testPasswordOnly, devices: .init(), actions: .init()) },
        .init("first-run-ready-all-added", .macWindow) {
            MacReadyPage(copied: .passwords(1), devices: .init(iPhone: phone, watch: "Research Team Apple Watch Ultra 3",
                                                               computers: [computer, "Research Team Mac mini"]), actions: .init())
        },
        .init("agent-note-sheet", .macPanel(width: MacDeviceSheet.width)) { MacAgentNoteSheet(agentNote: agentNote) {} },
    ] }

    // MARK: Adding an iPhone or a computer

    private static func iPhone(_ state: MacAddIPhoneSheet.State) -> MacAddIPhoneSheet { MacAddIPhoneSheet(state, checkAgain: {}, close: {}) }
    private static func computer(_ state: MacAddComputerSheet.State) -> MacAddComputerSheet { MacAddComputerSheet(state, actions: .init()) }

    private static var sheets: [KeyringGalleryEntry] {
        let width = KeyringGalleryEntry.Kind.macPanel(width: MacDeviceSheet.width)
        return [
            .init("add-iphone-no-tailscale", width) { iPhone(.noTailscale) },
            .init("add-iphone-door-problem", width) { iPhone(.doorProblem(MessageCopy.doorClosed("another program is using port 17447."))) },
            .init("add-iphone-waiting", width) { iPhone(.waiting(notAdded: nil)) },
            .init("add-iphone-not-added", width) { iPhone(.waiting(notAdded: phone)) },
            .init("add-iphone-join-asked", width) { iPhone(.joinAsked(name: phone)) },
            .init("add-iphone-copying", width) { iPhone(.copying(name: phone, done: 1_250, total: 1_547)) },
            .init("add-iphone-stopped", width) {
                iPhone(.stopped(name: phone, done: 1_250, total: 1_547, reason: "This Mac couldn’t save the copies."))
            },
            .init("add-iphone-added", width) { iPhone(.added(name: phone)) },
            .init("add-computer-no-tailscale", width) { computer(.noTailscale) },
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

    private static func question(_ changes: (Int, Int, Int)) -> some View {
        MacQuestionPanelView(title: SetupCopy.sendChangesTitle(changes.0 + changes.1 + changes.2),
                             message: SetupCopy.sendChangesBody(added: changes.0, changed: changes.1, removed: changes.2),
                             approval: OwnerApproval(action: SetupCopy.allow.lowercased(), reason: SetupCopy.sendChangesReason,
                                                     perform: { _ in }, finish: { _ in }))
    }

    private static var cards: [KeyringGalleryEntry] {
        let width = KeyringGalleryEntry.Kind.macPanel(width: MacApprovalPanelView.width)
        let waiting = AccessRequestState.waitingForYou(until: .distantFuture)
        let practice = AccessRequest.practice(id: "p", state: waiting)
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
            .init("card-request-approved", width) { ReviewRendering.panel(request(.approved(by: .mac, until: .now.addingTimeInterval(1_800)))) },
            .init("card-request-denied-with-reply", width) { ReviewRendering.panel(request(.denied(by: .mac, reply: reply, askAgainAfter: nil))) },
            .init("card-request-no-answer", width) { ReviewRendering.panel(request(.unanswered)) },
            .init("card-practice", width) { ReviewRendering.panel(practice) },
            .init("card-practice-approved", width) { ReviewRendering.panel(.practice(id: "p", state: .approved(by: .mac, until: .now))) },
            .init("card-add-iphone", width) { ReviewRendering.panel(join(SetupCopy.addIPhoneLead, phone, SetupCopy.addIPhoneBody, replies: false)) },
            .init("card-add-iphone-copying", width) {
                ReviewRendering.panel(join(SetupCopy.addIPhoneLead, phone, SetupCopy.addIPhoneBody, replies: false,
                                           approved: SetupCopy.copyingTo(done: 1_250, total: 1_547), state: .approved(by: .mac, until: .now)))
            },
            .init("card-add-watch", width) {
                ReviewRendering.panel(join(SetupCopy.addWatchLead, "Research Team Apple Watch Ultra 3", SetupCopy.addWatchBody, replies: false))
            },
            .init("card-add-computer", width) { ReviewRendering.panel(join(SetupCopy.addComputerLead, computer, SetupCopy.addComputerBody, replies: true)) },
            .init("card-add-computer-denied", width) {
                ReviewRendering.panel(join(SetupCopy.addComputerLead, computer, SetupCopy.addComputerBody, replies: true,
                                           state: .denied(by: .mac, reply: nil, askAgainAfter: nil)))
            },
            .init("question-send-changes", .macPanel(width: 380)) { question((1_212, 24, 13)) },
            .init("question-send-changes-removed-only", .macPanel(width: 380)) { question((0, 0, 2)) },
            .init("question-send-changes-one", .macPanel(width: 380)) { question((0, 1, 0)) },
        ]
    }
}
#endif
