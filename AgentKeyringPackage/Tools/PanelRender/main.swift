// Written by AI on 2026.11.18 by model claude opus 5.5; first run and the
// practice request added on 2026.11.19 by model claude opus 5.5.
// Draws the request panel, the menu bar and the main window off screen, light and
// dark, for a design check against Paper. First run is drawn by the galleries (2026.11.21). Nothing appears on screen.
// Since 2026.11.21 (claude opus 5.5) it also draws every Mac part and page
// in the galleries through the cut-off check, and prints what it found.
// Since 2026.11.27 (claude opus 5.5) the main window runs on the sandbox world:
// the built-in one, or a keyring dumped with every password "hunter2"
// (--bundle <file>).
import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import AgentKeyringDesign
import AgentKeyringSealing
import AppKit
import SwiftUI
import UniformTypeIdentifiers

_ = NSApplication.shared
let arguments = Array(CommandLine.arguments.dropFirst())
let bundlePath = arguments.firstIndex(of: "--bundle").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
let out = URL(fileURLWithPath: arguments.first { $0 != "--bundle" && $0 != bundlePath } ?? "/tmp/panel-render")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let request = AccessRequest(id: "r", login: RequestedLogin(site: "example.com", account: "you@example.com"),
    agent: RequestingAgent(name: "Codex", machine: "Mac mini", address: "100.64.0.2", folder: "~/code/bookkeeping", project: "bookkeeping"),
    access: .login, agentReason: "You asked me to download October’s invoice.", askedAt: .now,
    state: .waitingForYou(until: .now.addingTimeInterval(600)))
var plainFolder = request; plainFolder.agent.project = nil; plainFolder.agent.folder = "~/Downloads/a-very-long-folder-name-for-invoices"
var home = request; home.agent.project = nil; home.agent.folder = "~"
var approved = request; approved.state = .approved(by: .mac, until: .now.addingTimeInterval(1800))
var denied = request; denied.state = .denied(by: .mac, reply: "The invoice is in my email. Use that.", askAgainAfter: nil)
let practice = AccessRequest.practiceAccessRequest(id: "practice", state: .waitingForYou(until: .distantFuture))
let practiceApproved = AccessRequest.practiceAccessRequest(id: "practice", state: .approved(by: .mac, until: .now))
var cancelled = request; cancelled.state = .cancelled
let addComputer = AccessRequest(id: "c", login: RequestedLogin(site: "Mac mini", account: ""),
    agent: RequestingAgent(name: "Claude Code", machine: "", address: "", isLocal: true),
    access: .setUp(lead: SetupCopy.addComputerLead, detail: SetupCopy.addComputerBody,
        footer: "", denied: SetupCopy.notAdded("Mac mini"), replies: true),
    agentReason: "You asked me to set up Agent Keyring on Mac mini.", askedAt: .now, state: .waitingForYou(until: .now.addingTimeInterval(600)))
let addPhone = AccessRequest(id: "p", login: RequestedLogin(site: "iPhone", account: ""),
    agent: RequestingAgent(name: "iPhone", machine: "iPhone", address: ""),
    access: .setUp(lead: SetupCopy.addIPhoneLead, detail: SetupCopy.addIPhoneBody,
        footer: "", denied: SetupCopy.notAdded("iPhone"), replies: false),
    agentReason: "", askedAt: .now, state: .waitingForYou(until: .now.addingTimeInterval(600)))
var computerDenied = addComputer; computerDenied.state = .denied(by: .mac, reply: nil, askAgainAfter: nil)
let invited = AccessRequest(id: "i", login: RequestedLogin(site: "Mac mini", account: ""),
    agent: RequestingAgent(name: "An agent", machine: "Mac mini", address: ""),
    access: .setUp(lead: SetupCopy.addComputerLead, detail: SetupCopy.addComputerBody,
        footer: "", denied: SetupCopy.notAdded("Mac mini"), replies: false),
    agentReason: "", askedAt: .now, state: .waitingForYou(until: .now.addingTimeInterval(600)))
var longName = request; longName.agent.name = "Research Assistant for Bookkeeping"
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
/// The built-in sandbox world, seen from its MacBook Pro, or a dumped one (--bundle <file>).
@MainActor func world(sampleOnly: Bool = false) -> SandboxWorld {
    var state = SandboxState.builtIn()
    if let bundlePath {
        do { state = try SandboxBundleCodec.state(from: Data(contentsOf: URL(fileURLWithPath: bundlePath))) } catch {
            print("Couldn't read the bundle at \(bundlePath): \(error)")
            exit(1)
        }
    } else {
        state.thisDeviceID = "macbook"
        state.practice = ["iphone": .withApple]
    }
    if sampleOnly {
        state.logins = state.logins.filter(\.isTestPassword)
        state.devices = state.devices.filter { $0.kind == .mac }
        state.mac.sampleOnly = true
    }
    return SandboxWorld(state)
}
@MainActor func mainWindow(_ world: SandboxWorld, tab: MacMainWindowTab) -> AnyView {
    let model = MacMainModel(backend: SandboxMainBackend(world), initial: world.state.macSnapshot)
    model.tab = tab
    return AnyView(MacMainWindowView(model: model) { _, _ in AnyView(EmptyView()) }.frame(width: 860, height: 640))
}
MainActor.assumeIsolated {
    // The main window in a real window, off screen, so its toolbar and native controls draw as macOS draws them.
    _ = NSApplication.shared
    for (name, sampleOnly, tab) in [("window-passwords", false, MacMainWindowTab.logins), ("window-devices", false, .devices),
        ("window-sample-only", true, .logins)] {
        for (appearance, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let host = NSHostingController(rootView: mainWindow(world(sampleOnly: sampleOnly), tab: tab))
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
    for (name, view) in cases {
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
            let result = ScreenCheck.runLayoutCheck(entry.view, on: screen)
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
