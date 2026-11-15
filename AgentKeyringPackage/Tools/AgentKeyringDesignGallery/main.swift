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
import AppKit
import SwiftUI

let arguments = CommandLine.arguments

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
