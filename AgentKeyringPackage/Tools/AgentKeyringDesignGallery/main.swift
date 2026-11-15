// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Shows one Mac design screen, from the real views and mock data, on a plain
// backdrop, and prints where the window is so a screenshot can be cropped.
// script/capture_mac_design_screens.sh runs it on the Mac mini.
//
// usage: agent-keyring-design-gallery SCREEN light|dark
//        agent-keyring-design-gallery render OUTDIR [SCREEN ...]
// SCREEN "leaseApproval" or "leaseMenuBar" shows lease records mapped through
// the real adapter instead of the mock examples.

import AgentKeyringApprovalUI
import AgentKeyringFeature
import AppKit
import SwiftUI

/// The main window's status panel before and after the first import.
@MainActor func renderMainWindow(to directory: URL) async {
    let imported = SafeMirrorStatus(generationID: UUID(), importedAt: .now.addingTimeInterval(-3 * 86_400),
        sourceExportedAt: .now.addingTimeInterval(-3 * 86_400), scope: .full, credentialItemCount: 542,
        skippedCredentialCount: 0)
    for (name, status) in [("mainSetUp", nil), ("mainImported", imported)] as [(String, SafeMirrorStatus?)] {
        let panel = MirrorStatusPanel(status: status, isLoading: false, isImporting: false, providerState: .unknown,
            notice: nil, enableProvider: {}, openPasswords: {}, manageAccess: {})
            .padding(24).frame(width: 720).tint(.blue)
        await MacDesignGallery.render(panel, title: "Agent Keyring", size: NSSize(width: 720, height: status == nil ? 380 : 560),
            name: name, to: directory)
    }
}

let arguments = CommandLine.arguments

// placement OUTDIR: where a request panel lands on common screen layouts,
// drawn from ApprovalPanelPlacement itself. The dashed box is the old spot,
// the top right of the screen.
if arguments.count >= 3, arguments[1] == "placement" {
    MainActor.assumeIsolated { renderPlacements(to: URL(filePath: arguments[2])) }
    exit(0)
}

// render OUTDIR [SCREEN ...]: every screen, light and dark, drawn to PNGs
// without a window on screen or an icon in the Dock.
if arguments.count >= 3, arguments[1] == "render" {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let directory = URL(filePath: arguments[2])
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let screens = arguments.count > 3 ? arguments[3...].compactMap(MacDesignScreen.init(rawValue:)) : MacDesignScreen.allCases
    Task { @MainActor in
        await MacDesignGallery.render(screens, to: directory)
        if arguments.count == 3 || arguments.contains("main") { await renderMainWindow(to: directory) }
        exit(0)
    }
    application.run()
}
let leaseScreens: [String: MacDesignScreen] = ["leaseApproval": .approval, "leaseMenuBar": .menuBar]
guard arguments.count >= 3, let screen = leaseScreens[arguments[1]] ?? MacDesignScreen(rawValue: arguments[1]) else {
    let names = MacDesignScreen.allCases.map(\.rawValue).joined(separator: ", ")
    FileHandle.standardError.write(Data("usage: \(arguments[0]) SCREEN light|dark\nscreens: \(names)\n".utf8))
    exit(2)
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.appearance = NSAppearance(named: arguments[2] == "dark" ? .darkAqua : .aqua)

MainActor.assumeIsolated {
    let gallery = MacDesignGallery(screen: screen,
        requests: leaseScreens[arguments[1]] == nil ? nil : LeaseRecords.requests())
    gallery.show()
    // Keep the gallery alive for the run loop.
    objc_setAssociatedObject(application, "gallery", gallery, .OBJC_ASSOCIATION_RETAIN)
}
application.activate()
application.run()

@MainActor func renderPlacements(to directory: URL) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let panel = CGSize(width: 380, height: 470)
    let bar: CGFloat = 35
    func visible(_ frame: CGRect) -> CGRect { CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - bar) }
    struct Layout { let name: String; let title: String; let screens: [CGRect]; let window: CGRect; let pointer: CGPoint }
    let wide = CGRect(x: 0, y: 0, width: 7680, height: 2160)
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
    let layouts = [
        Layout(name: "placement-ultrawide", title: "57-inch screen (7680 × 2160), window in the middle",
            screens: [wide], window: CGRect(x: 2940, y: 420, width: 1800, height: 1300), pointer: CGPoint(x: 3800, y: 900)),
        Layout(name: "placement-ultrawide-wide-window", title: "57-inch screen, window across almost all of it",
            screens: [wide], window: CGRect(x: 200, y: 100, width: 7280, height: 1980), pointer: CGPoint(x: 3600, y: 800)),
        Layout(name: "placement-laptop", title: "Laptop (1512 × 982), window filling the screen",
            screens: [laptop], window: visible(laptop), pointer: CGPoint(x: 700, y: 400)),
        Layout(name: "placement-two-screens", title: "Laptop plus a 2560 × 1440 screen, window on the second",
            screens: [laptop, external], window: CGRect(x: 1600, y: 60, width: 1500, height: 1300), pointer: CGPoint(x: 2300, y: 700)),
    ]
    for layout in layouts {
        let frames = layout.screens.map(visible)
        let placed = ApprovalPanelPlacement.frame(panel: panel, focusedWindow: layout.window, pointer: layout.pointer,
            visibleFrames: frames)
        let pointerScreen = frames.first { $0.contains(layout.pointer) } ?? frames[0]
        let old = CGRect(x: pointerScreen.maxX - panel.width - 12, y: pointerScreen.maxY - 8 - panel.height,
            width: panel.width, height: panel.height)
        let union = layout.screens.reduce(CGRect.null) { $0.union($1) }
        let scale = 1400 / union.width, margin: CGFloat = 30, titleHeight: CGFloat = 40
        let size = CGSize(width: union.width * scale + 2 * margin, height: union.height * scale + 2 * margin + titleHeight)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); CGRect(origin: .zero, size: size).fill()
        func map(_ r: CGRect) -> CGRect {
            CGRect(x: margin + (r.minX - union.minX) * scale, y: margin + (r.minY - union.minY) * scale,
                width: r.width * scale, height: r.height * scale)
        }
        func label(_ text: String, _ r: CGRect, _ colour: NSColor) {
            (text as NSString).draw(at: CGPoint(x: r.minX + 6, y: r.maxY - 20),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: colour])
        }
        for screen in layout.screens {
            NSColor(white: 0.9, alpha: 1).setFill(); NSBezierPath(rect: map(screen)).fill()
            NSColor(white: 0.6, alpha: 1).setStroke(); NSBezierPath(rect: map(screen)).stroke()
        }
        NSColor(srgbRed: 0.8, green: 0.88, blue: 1, alpha: 1).setFill(); NSBezierPath(rect: map(layout.window)).fill()
        label("Your window", map(layout.window), .black)
        let dashed = NSBezierPath(rect: map(old)); dashed.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.gray.setStroke(); dashed.stroke(); label("Before", map(old), .gray)
        NSColor(srgbRed: 0.04, green: 0.29, blue: 0.84, alpha: 1).setFill(); NSBezierPath(rect: map(placed)).fill()
        label("Request", map(placed), .white)
        let p = map(CGRect(origin: layout.pointer, size: .zero)).origin
        NSColor.black.setFill(); NSBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill()
        (layout.title as NSString).draw(at: CGPoint(x: margin, y: size.height - titleHeight + 8),
            withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.black])
        NSGraphicsContext.current?.flushGraphics()
        let url = directory.appending(path: "\(layout.name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
    }
}
