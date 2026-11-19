// Written by AI on 2026.11.18 by model claude opus 5.5; first run and the
// practice request added on 2026.11.19 by model claude opus 5.5.
// Draws the request panel and the first-run windows off screen, light and
// dark, for a design check against Paper. Nothing appears on screen.
import AgentKeyringApprovalUI
import AppKit
import SwiftUI

_ = NSApplication.shared
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/panel-render")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let request = AccessRequest(id: "r", login: RequestedLogin(site: "example.com", account: "josh@example.com"),
    agent: RequestingAgent(name: "Codex", machine: "Mac mini", address: "100.64.0.2", folder: "~/code/bookkeeping", project: "bookkeeping"),
    access: .login, agentReason: "You asked me to download October’s invoice.", askedAt: .now,
    state: .waitingForYou(until: .now.addingTimeInterval(600)))
var plainFolder = request; plainFolder.agent.project = nil; plainFolder.agent.folder = "~/Downloads/a-very-long-folder-name-for-invoices"
var home = request; home.agent.project = nil; home.agent.folder = "~"
var approved = request; approved.state = .approved(by: .mac, until: .now.addingTimeInterval(1800))
var denied = request; denied.state = .denied(by: .mac, reply: "The invoice is in my email. Use that.", askAgainAfter: nil)
let practice = AccessRequest.practice(id: "practice", state: .waitingForYou(until: .distantFuture))
let practiceApproved = AccessRequest.practice(id: "practice", state: .approved(by: .mac, until: .now))
let agentLine = FirstRunCopy.agentLine(appPath: "/Applications/Agent Keyring.app")
let cases: [(String, AnyView)] = [
    ("waiting", AnyView(ReviewRendering.panel(request))),
    ("waiting-for-touch", AnyView(ReviewRendering.panel(request, waiting: true))),
    ("folder", AnyView(ReviewRendering.panel(plainFolder))),
    ("home", AnyView(ReviewRendering.panel(home))),
    ("typing", AnyView(ReviewRendering.panel(request, reply: "The invoice is in my email. Use that."))),
    ("approved", AnyView(ReviewRendering.panel(approved))),
    ("denied", AnyView(ReviewRendering.panel(denied))),
    ("practice", AnyView(ReviewRendering.panel(practice))),
    ("practice-after-click", AnyView(ReviewRendering.panel(practice, waiting: true))),
    ("practice-approved", AnyView(ReviewRendering.panel(practiceApproved))),
    ("first-run-1-export", AnyView(MacFirstRunView(step: .export))),
    ("first-run-1a-autofill", AnyView(MacFirstRunView(step: .autoFill(canAsk: true)))),
    ("first-run-1a-not-now", AnyView(MacFirstRunView(step: .autoFillNotNow(canAsk: true)))),
    ("first-run-1-none-arrived", AnyView(MacFirstRunView(step: .noneArrived))),
    ("first-run-copying", AnyView(MacFirstRunView(step: .copying))),
    ("first-run-2-practice", AnyView(MacFirstRunView(step: .practice(passwords: 542, denied: false)))),
    ("first-run-2-practice-denied", AnyView(MacFirstRunView(step: .practice(passwords: 542, denied: true)))),
    ("first-run-3-set-up", AnyView(MacFirstRunView(step: .setUp(agentLine: agentLine)))),
]
MainActor.assumeIsolated {
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
