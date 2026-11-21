// Written by AI on 2026.11.18 by model claude opus 5.5; first run and the
// practice request added on 2026.11.19 by model claude opus 5.5.
// Draws the request panel, the menu bar and the main window off screen, light and
// dark, for a design check against Paper. First run is drawn by the galleries (2026.11.21). Nothing appears on screen.
// Since 2026.11.21 (claude opus 5.5) it also draws every Mac part and page
// in the galleries through the cut-off check, and prints what it found.
import AgentKeyringApprovalUI
import AgentKeyringDesign
import AppKit
import UniformTypeIdentifiers
import LocalAuthentication
import SwiftUI

_ = NSApplication.shared
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/panel-render")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let request = AccessRequest(id: "r", login: RequestedLogin(site: "example.com", account: "you@example.com"),
    agent: RequestingAgent(name: "Codex", machine: "Mac mini", address: "100.64.0.2", folder: "~/code/bookkeeping", project: "bookkeeping"),
    access: .login, agentReason: "You asked me to download October’s invoice.", askedAt: .now,
    state: .waitingForYou(until: .now.addingTimeInterval(600)))
var plainFolder = request; plainFolder.agent.project = nil; plainFolder.agent.folder = "~/Downloads/a-very-long-folder-name-for-invoices"
var home = request; home.agent.project = nil; home.agent.folder = "~"
var approved = request; approved.state = .approved(by: .mac, until: .now.addingTimeInterval(1800))
var denied = request; denied.state = .denied(by: .mac, reply: "The invoice is in my email. Use that.", askAgainAfter: nil)
let practice = AccessRequest.practice(id: "practice", state: .waitingForYou(until: .distantFuture))
let practiceApproved = AccessRequest.practice(id: "practice", state: .approved(by: .mac, until: .now))
var cancelled = request; cancelled.state = .cancelled
let addComputer = AccessRequest(id: "c", login: RequestedLogin(site: "Mac mini", account: ""),
    agent: RequestingAgent(name: "Claude Code", machine: "", address: "", isLocal: true),
    access: .setUp(lead: SetupCopy.addComputerLead, detail: SetupCopy.addComputerBody,
        footer: "", denied: SetupCopy.notAdded("Mac mini"), replies: true),
    agentReason: "You asked me to set up Agent Keyring on Mac mini.", askedAt: .now, state: .waitingForYou(until: .now.addingTimeInterval(600)))
let addPhone = AccessRequest(id: "p", login: RequestedLogin(site: "iPhone 17 Pro", account: ""),
    agent: RequestingAgent(name: "iPhone 17 Pro", machine: "iPhone 17 Pro", address: ""),
    access: .setUp(lead: SetupCopy.addIPhoneLead, detail: SetupCopy.addIPhoneBody,
        footer: "", denied: SetupCopy.notAdded("iPhone 17 Pro"), replies: false),
    agentReason: "", askedAt: .now, state: .waitingForYou(until: .now.addingTimeInterval(600)))
let practiceRows = [
    PracticeRow(id: "d1", name: "This Mac", symbol: "laptopcomputer", detail: FirstRunCopy.practiceApprovedAt("14:02", touchID: true), tone: .approved, canSend: true),
    PracticeRow(id: "d2", name: "iPhone 17 Pro", symbol: "iphone", detail: FirstRunCopy.practiceDeniedAt("14:03", reply: "Use the work account instead."), tone: .denied, canSend: true),
    PracticeRow(id: "d3", name: "Apple Watch Ultra 3", symbol: "applewatch", detail: FirstRunCopy.practiceOnWrist("14:03"), tone: .plain, canSend: false),
]
var computerDenied = addComputer; computerDenied.state = .denied(by: .mac, reply: nil, askAgainAfter: nil)
let invited = AccessRequest(id: "i", login: RequestedLogin(site: "Mac mini", account: ""),
    agent: RequestingAgent(name: "An agent", machine: "Mac mini", address: ""),
    access: .setUp(lead: SetupCopy.addComputerLead, detail: SetupCopy.addComputerBody,
        footer: "", denied: SetupCopy.notAdded("Mac mini"), replies: false),
    agentReason: "", askedAt: .now, state: .waitingForYou(until: .now.addingTimeInterval(600)))
var longName = request; longName.agent.name = "Research Assistant for Bookkeeping"
func at(_ hour: Int, _ minute: Int) -> Date { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now)! }
func row(_ site: String, _ agent: String, _ computer: String?, _ hour: Int, _ minute: Int, _ state: AccessRequestState, project: String? = nil, automatic: Bool = false) -> AccessRequest {
    AccessRequest(id: site + agent + "\(hour)", login: RequestedLogin(site: site, account: "you@example.com"),
        agent: RequestingAgent(name: agent, machine: computer ?? "", address: "", project: project, isLocal: computer == nil),
        access: .login, agentReason: "", askedAt: at(hour, minute), state: state, byAutomaticRule: automatic)
}
let earlier = [row("shop.example", "Claude Code", nil, 13, 40, .released(at: at(13, 50))),
    row("forum.example", "Codex", "Linux server", 13, 12, .denied(by: .mac, reply: nil, askAgainAfter: nil)),
    row("example.com", "Codex", "Mac mini", 11, 5, .unanswered),
    row("news.example", "Codex", "Mac mini", 9, 30, .released(at: at(9, 31)), automatic: true)]
final class MenuStub: MacMenuBarBackend {
    func updates() -> AsyncStream<MacMenuBarSnapshot> { AsyncStream { $0.finish() } }
    func endAccess(requestID: String) async throws -> AccessRequestState { .cancelled }
    func allowAskingAgain(requestID: String) async throws -> AccessRequestState { .cancelled }
}
@MainActor func menu(_ snapshot: MacMenuBarSnapshot) -> AnyView {
    AnyView(MacMenuBarView(model: MacMenuBarModel(backend: MenuStub(), initial: snapshot)).clipShape(.rect(cornerRadius: 16)))
}
let cases: [(String, AnyView)] = [
    ("waiting", AnyView(ReviewRendering.panel(request))),
    ("waiting-for-touch", AnyView(ReviewRendering.panel(request, waiting: true))),
    ("folder", AnyView(ReviewRendering.panel(plainFolder))),
    ("home", AnyView(ReviewRendering.panel(home))),
    ("typing", AnyView(ReviewRendering.panel(request, reply: "The invoice is in my email. Use that."))),
    ("approved", AnyView(ReviewRendering.panel(approved))),
    ("denied", AnyView(ReviewRendering.panel(denied))),
    ("cancelled", AnyView(ReviewRendering.panel(cancelled))),
    ("add-computer", AnyView(ReviewRendering.panel(addComputer))),
    ("add-computer-denied", AnyView(ReviewRendering.panel(computerDenied))),
    ("add-iphone", AnyView(ReviewRendering.panel(addPhone))),
    ("add-computer-without-agent", AnyView(ReviewRendering.panel(invited))),
    ("long-agent-name", AnyView(ReviewRendering.panel(longName))),
    ("lid-closed-elsewhere", AnyView(ReviewRendering.panel(request, lidClosed: true, approvesElsewhere: true))),
    ("practice-lid-closed", AnyView(ReviewRendering.panel(practice, lidClosed: true))),
    ("practice", AnyView(ReviewRendering.panel(practice))),
    ("practice-after-click", AnyView(ReviewRendering.panel(practice, waiting: true))),
    ("practice-approved", AnyView(ReviewRendering.panel(practiceApproved))),
    ("menu-bar-tip", AnyView(MenuBarTipView())),
]
final class StubBackend: MainWindowBackend {
    func updates() -> AsyncStream<MainSnapshot> { AsyncStream { $0.finish() } }
    func saveRules(_ changes: [UUID: LoginRule], context: LAContext) async throws {}
    func remove(id: String, context: LAContext) async throws {}
    func importAgain() {}
    func sendPractice(deviceID: String) {}
}
let thisMac = DeviceRow(practice: practiceRows[0], isThisMac: true)
let plainRows = [
    PracticeRow(id: "d1", name: "MacBook Pro", symbol: "laptopcomputer", detail: "This Mac · You answer with Touch ID", tone: .plain, canSend: true),
    PracticeRow(id: "d2", name: "iPhone", symbol: "iphone", detail: MainWindowCopy.phoneAnswers, tone: .plain, canSend: true),
    PracticeRow(id: "d3", name: "Apple Watch", symbol: "applewatch", detail: MainWindowCopy.watchAnswers, tone: .plain, canSend: true),
]
let logins = [("example.com", LoginRule.ask), ("news.example", .ask), ("forum.example", .automatic), ("old.example", .blocked)]
    .map { LoginRow(id: UUID(), site: $0.0, account: "you@example.com", rule: $0.1) }
let alone = MainSnapshot(logins: logins, importedAt: .now, devices: [DeviceRow(practice: plainRows[0], isThisMac: true)],
    machines: [MachineRow(id: "m1", name: "MacBook Pro", isThisMac: true)])
let everything = MainSnapshot(logins: logins, importedAt: .now,
    devices: plainRows.enumerated().map { DeviceRow(practice: $1, isThisMac: $0 == 0) },
    machines: [MachineRow(id: "m1", name: "MacBook Pro", isThisMac: true),
        MachineRow(id: "m2", name: "Mac mini", isThisMac: false),
        MachineRow(id: "m3", name: "Linux server", isThisMac: false)])
@MainActor func mainWindow(_ snapshot: MainSnapshot, tab: MacMainModel.Tab, makeAutomatic: Bool = false) -> AnyView {
    let model = MacMainModel(backend: StubBackend(), initial: snapshot)
    model.tab = tab
    if makeAutomatic { model.choose(.automatic, for: snapshot.logins[1]) }
    return AnyView(MacMainWindowView(model: model))
}
MainActor.assumeIsolated {
    let windows: [(String, AnyView)] = [
        ("menu-bar-open", menu(MacMenuBarSnapshot(requests: [
            row("example.com", "Codex", "Mac mini", 14, 1, .waitingForYou(until: .now.addingTimeInterval(500)), project: "bookkeeping"),
            row("example.org", "Claude Code", nil, 14, 2, .approved(by: .mac, until: at(14, 32)))] + earlier, passwordCount: 542))),
        ("menu-bar-nothing", menu(MacMenuBarSnapshot(requests: earlier, passwordCount: 542))),
        ("menu-bar-offline", menu(MacMenuBarSnapshot(requests: earlier, offlineComputer: "Mac mini", passwordCount: 542))),
        ("devices-this-mac-only", mainWindow(alone, tab: .devices)),
        ("devices-everything", mainWindow(everything, tab: .devices)),
        ("passwords-rule-bar-automatic", mainWindow(everything, tab: .logins, makeAutomatic: true)),
    ]
    // The main window in a real window, off screen, so its toolbar and native controls draw as macOS draws them.
    _ = NSApplication.shared
    for (name, snapshot, tab) in [("window-passwords", everything, MacMainModel.Tab.logins), ("window-devices", everything, .devices),
        ("window-sample-only", MainSnapshot(logins: [logins[0]], importedAt: .now, devices: [thisMac], machines: alone.machines), .logins)] {
        for (appearance, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let host = NSHostingController(rootView: mainWindow(snapshot, tab: tab))
            host.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.appearance = NSAppearance(named: appearance)
            window.layoutIfNeeded()
            RunLoop.main.run(until: .now.addingTimeInterval(0.3))
            guard let frame = window.contentView?.superview, let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)-\(label).png"))
            print(name, label, Int(frame.bounds.width), "x", Int(frame.bounds.height))
        }
    }
    for (name, view) in cases + windows {
        for (scheme, label) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).padding(30).background(scheme == .dark ? Color(white: 0.1) : Color(white: 0.93)))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: out.appendingPathComponent("\(name)-\(label).png"))
            print(name, label, Int(image.size.width), "x", Int(image.size.height))
        }
    }
}

// The parts and pages, drawn exactly as the cut-off check hosts them.
MainActor.assumeIsolated {
    for entry in KeyringGallery.parts + PageGallery.entries {
        for screen in KeyringScreen.all(for: entry.kind) {
            let result = ScreenCheck.run(entry.view, on: screen)
            let name = "gallery-\(entry.id)-\(screen.name)"
            if let image = result.image, let destination = CGImageDestinationCreateWithURL(
                out.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
            try? (result.words.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
            print(name, result.findings.isEmpty ? "fits" : result.findings.map(\.description).joined(separator: "; "))
        }
    }
}
