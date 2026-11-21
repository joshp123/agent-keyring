// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// The Mac's everyday pages for the cut-off check (PageGallery): Devices,
// Passwords, Sort with AI and the menu bar window, in each state worth
// seeing, with the longest words each holds. Sample data only: made-up
// names and example sites.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import LocalAuthentication
import SwiftUI

@MainActor
enum MacEverydayGallery {
    static var entries: [KeyringGalleryEntry] {
        [
            // Devices scrolls in the window, so it is checked to its last row.
            .init("devices-iphone-practice-under-way", .macPanel(width: KeyringSize.macWindow.width)) {
                MacDevicesTab(model: main(approvers: [
                    ApproverRow(id: "mac", kind: .thisMac, name: Sample.macName, canPractise: true),
                    ApproverRow(id: "phone", kind: .iPhone, name: "iPhone", practice: .arrived, canPractise: false),
                    ApproverRow(id: "watch", kind: .watch, name: "Apple Watch", practice: .withApple, canPractise: false),
                ], computers: [ComputerRow(id: "mini", name: "Mac mini"), ComputerRow(id: "linux", name: "build-server.example")]))
            },
            .init("devices-practice-answered", .macPanel(width: KeyringSize.macWindow.width)) {
                MacDevicesTab(model: main(approvers: [
                    ApproverRow(id: "mac", kind: .thisMac, name: Sample.macName, practice: .approved, canPractise: true),
                    ApproverRow(id: "phone", kind: .iPhone, name: "iPhone", practice: .denied, canPractise: true),
                    ApproverRow(id: "watch", kind: .watch, name: "Apple Watch", practice: .noAnswer, canPractise: true),
                    ApproverRow(id: "phone2", kind: .iPhone, name: "Work iPhone",
                                practice: .failed(MessageCopy.noPushAddress("Work iPhone")), canPractise: true),
                ], computers: [ComputerRow(id: "mini", name: "Mac mini")]))
            },
            .init("devices-this-mac-alone-no-tailscale", .macPanel(width: KeyringSize.macWindow.width)) {
                MacDevicesTab(model: main(approvers: [
                    ApproverRow(id: "mac", kind: .thisMac, name: Sample.macName, practice: .waitingHere, canPractise: false),
                ], notices: [.noTailscale, .noPushKey]))
            },
            .init("devices-changes-not-sent", .macPanel(width: KeyringSize.macWindow.width)) {
                MacDevicesTab(model: main(approvers: [
                    ApproverRow(id: "mac", kind: .thisMac, name: Sample.macName, canPractise: true),
                    ApproverRow(id: "phone", kind: .iPhone, name: "iPhone", canPractise: true),
                ], computers: [ComputerRow(id: "mini", name: "Mac mini")], unsentChanges: 1_249))
            },
            .init("devices-door-failed", .macPanel(width: KeyringSize.macWindow.width)) {
                MacDevicesTab(model: main(approvers: [
                    ApproverRow(id: "mac", kind: .thisMac, name: Sample.macName, canPractise: true),
                    ApproverRow(id: "phone", kind: .iPhone, name: "iPhone", canPractise: false),
                ], notices: [.failed]))
            },
            .init("passwords", .macWindow) { MacPasswordsTab(model: main()) },
            .init("passwords-rule-changed-to-automatic", .macWindow) {
                let model = main(computers: [ComputerRow(id: "mini", name: "Mac mini"), ComputerRow(id: "linux", name: "build-server.example")])
                model.choose(.automatic, for: Sample.logins[1])
                return MacPasswordsTab(model: model)
            },
            .init("passwords-filtered-blocked", .macWindow) {
                let model = main()
                model.filter = .blocked
                return MacPasswordsTab(model: model)
            },
            .init("passwords-test-password-only", .macWindow) {
                MacPasswordsTab(model: MacMainModel(backend: SampleMainBackend(), initial: MainSnapshot(
                    logins: [Sample.logins[2]], importedAt: nil, sampleOnly: true)))
            },
            .init("sort-with-ai", .macPanel(width: KeyringSize.measure + 2 * KeyringSpace.s10)) {
                SortWithAISheet(model: main()) {}
            },
            .init("menu-bar-waiting-in-use-earlier", .macPanel(width: Sample.menuWidth)) {
                menu(MacMenuBarSnapshot(requests: [
                    Sample.request("mail.example", agent: "Codex", on: "Mac mini", reason: "You asked me to download October’s invoice.",
                                   state: .waitingForYou(until: .now.addingTimeInterval(500))),
                    Sample.request("example.org", agent: "Claude Code", on: nil, state: .approved(by: .mac, until: .now.addingTimeInterval(1500))),
                    // Another computer's: stopped from the iPhone, so no Stop here.
                    Sample.request("wiki.example", agent: "Codex", on: "Mac mini", state: .approved(by: .iPhone, until: .now.addingTimeInterval(1200))),
                ] + Sample.earlier, passwordCount: 547))
            },
            .init("menu-bar-longest", .macPanel(width: Sample.menuWidth)) {
                menu(MacMenuBarSnapshot(requests: [
                    Sample.request(Sample.longSite, agent: Sample.longAgent, on: Sample.macName, reason: Sample.longReason,
                                   state: .waitingForYou(until: .now.addingTimeInterval(500))),
                    Sample.request(Sample.longSite, agent: Sample.longAgent, on: nil, state: .approved(by: .mac, until: .now.addingTimeInterval(1500))),
                ], enrolments: [DeviceEnrolment(id: "j", kind: .machine, name: "build-server.example", tailnetNode: "", code: "", askedAt: .now)],
                    passwordCount: 1))
            },
            .init("menu-bar-all-quiet", .macPanel(width: Sample.menuWidth)) {
                menu(MacMenuBarSnapshot(requests: Array(Sample.earlier.prefix(2)), passwordCount: 547))
            },
            .init("menu-bar-offline", .macPanel(width: Sample.menuWidth)) {
                menu(MacMenuBarSnapshot(requests: [], offline: true, passwordCount: 547))
            },
        ]
    }

    private static func main(approvers: [ApproverRow] = [], computers: [ComputerRow] = [], notices: [DoorNotice] = [],
                             unsentChanges: Int = 0) -> MacMainModel {
        MacMainModel(backend: SampleMainBackend(), initial: MainSnapshot(logins: Sample.logins, importedAt: Sample.copiedOn,
            approvers: approvers, computers: computers, notices: notices, unsentChanges: unsentChanges))
    }

    private static func menu(_ snapshot: MacMenuBarSnapshot) -> MacMenuBarView {
        MacMenuBarView(model: MacMenuBarModel(backend: SampleMenuBackend(), initial: snapshot))
    }
}

private enum Sample {
    static let menuWidth: CGFloat = 360
    static let macName = "Research Team MacBook Pro"
    static let longSite = "accounts.longcompany-example.example"
    static let longAgent = "Research Assistant for Bookkeeping"
    static let longReason = "You asked me to download October’s invoice from the billing page and attach it to the expenses report."
    static let copiedOn = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 20))

    static let logins: [LoginRow] = [
        LoginRow(id: UUID(), site: "news.example", account: "you@example.com", rule: .automatic, asked: 41, approved: 38, denied: 3),
        LoginRow(id: UUID(), site: "mail.example", account: "you@example.com", rule: .ask, asked: 17, approved: 15, denied: 2),
        LoginRow(id: UUID(), site: "example.com", account: "you@example.com", rule: .ask, asked: 4, approved: 3, denied: 1, isTestPassword: true),
        LoginRow(id: UUID(), site: longSite, account: "firstname.lastname.for.work@example.com", rule: .ask, asked: 2, approved: 2),
        LoginRow(id: UUID(), site: "old.example", account: "you@example.com", rule: .blocked),
        LoginRow(id: UUID(), site: "shop.example", account: "orders@example.com", rule: .ask, asked: 1, denied: 1),
    ]

    static func request(_ site: String, agent: String, on computer: String?, reason: String = "", state: AccessRequestState,
                        minutesAgo: Double = 1, automatic: Bool = false) -> AccessRequest {
        AccessRequest(id: site + agent + "\(minutesAgo)", login: RequestedLogin(site: site, account: "you@example.com"),
            agent: RequestingAgent(name: agent, machine: computer ?? "", address: "", isLocal: computer == nil),
            access: .login, agentReason: reason, askedAt: .now.addingTimeInterval(-minutesAgo * 60), state: state, byAutomaticRule: automatic)
    }

    static var earlier: [AccessRequest] { [
        request("shop.example", agent: "Claude Code", on: nil, state: .released(at: .now), minutesAgo: 2),
        request("forum.example", agent: "Codex", on: "Mac mini", state: .denied(by: .mac, reply: nil, askAgainAfter: nil), minutesAgo: 3),
        request("news.example", agent: "Codex", on: "Mac mini", state: .released(at: .now), minutesAgo: 4, automatic: true),
        request("docs.example", agent: "Claude Code", on: nil, state: .ended(at: .now), minutesAgo: 5),
    ] }
}

private final class SampleMainBackend: MainWindowBackend {
    func updates() -> AsyncStream<MainSnapshot> { AsyncStream { $0.finish() } }
    func saveRules(_ changes: [UUID: LoginRule], context: LAContext) async throws {}
    func remove(id: String, context: LAContext) async throws {}
    func rename(id: String, to newName: String, context: LAContext) async throws {}
    func importAgain() {}
    func sendPractice(deviceID: String) {}
    func sendUpdates() {}
}

private final class SampleMenuBackend: MacMenuBarBackend {
    func updates() -> AsyncStream<MacMenuBarSnapshot> { AsyncStream { $0.finish() } }
    func endAccess(requestID: String) async throws -> AccessRequestState { .ended(at: .now) }
    func allowAskingAgain(requestID: String) async throws -> AccessRequestState { .unanswered }
}
#endif
