// Written by AI on 2026.11.18 by model claude opus 5.5. Test branch only:
// draws the request panel off screen, light and dark, for a design check.
import AgentKeyringApprovalUI
import AppKit
import SwiftUI

_ = NSApplication.shared
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/panel-render")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let request = AccessRequest(id: "r", login: RequestedLogin(site: "example.com", account: "josh@example.com"),
    agent: RequestingAgent(name: "Codex", machine: "Mac mini", address: "100.64.0.2", folder: "/Users/josh/code/bookkeeping"),
    access: .signIn, agentReason: "You asked me to download October’s invoice.", askedAt: .now,
    state: .waitingForYou(until: .now.addingTimeInterval(600)))
var approved = request; approved.state = .approved(by: .mac, until: .now.addingTimeInterval(1800))
var denied = request; denied.state = .denied(by: .mac, reply: "The invoice is in my email. Use that.", askAgainAfter: nil)
let cases: [(String, AnyView)] = [
    ("waiting", AnyView(ReviewRendering.panel(request))),
    ("waiting-clicked", AnyView(ReviewRendering.panel(request, active: true))),
    ("typing", AnyView(ReviewRendering.panel(request, reply: "The invoice is in my email. Use that.", active: true))),
    ("approved", AnyView(ReviewRendering.panel(approved))),
    ("denied", AnyView(ReviewRendering.panel(denied))),
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
