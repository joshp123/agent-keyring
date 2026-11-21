// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Hosts every part, and every page added to the gallery, at the smallest
// size each device gives it, and fails on any text or button that is cut
// off, outside the screen or on top of another. Runs on the platform it is
// built for: `swift test` checks the Mac; the same tests on an iPhone or
// Watch simulator check those (docs/design/page-parts.md says how).
//
// Set KEYRING_RENDER_DIR to also write each screen as a PNG, with its words
// beside it in a .txt file.

import AgentKeyringDesign
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

@MainActor
@Suite struct NothingIsCutOff {
    @Test func everyPartFitsAtTheSmallestSize() throws {
        try checkAll(KeyringGallery.parts)
    }

    /// The check itself: the green button Josh found cut off at "Click here,
    /// then touch the sen…" (beside Cancel, in the 380-point question panel)
    /// must be reported. If this passes silently, the check has gone blind.
    @Test func theCheckCatchesTheCutOffGreenButton() {
        let cutOff = HStack(spacing: 10) {
            KeyringText("Click here, then touch the sensor to let agents on your other computers use the passwords you just copied", as: .label)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            KeyringButton(.plain("Not now") {}).frame(maxWidth: 110)
        }
        .padding(18)
        .frame(width: 380)
        let result = ScreenCheck.run(cutOff, on: KeyringScreen("light", size: CGSize(width: 380, height: 0), scrolls: true))
        #expect(result.findings.contains { if case .truncated = $0 { true } else { false } }, "\(result.findings)")
    }

    /// A button too narrow for its one word ("Ap-prove") must be reported.
    @Test func theCheckCatchesAWordSplitAcrossLines() {
        let narrow = KeyringText("Approve", as: .title).frame(width: 40)
        let result = ScreenCheck.run(narrow, on: KeyringScreen("light", size: CGSize(width: 40, height: 0), scrolls: true))
        #expect(result.findings.contains(.brokenWord("Approve")), "\(result.findings)")
    }

    /// Text pushed past the bottom of the Mac window must be reported too.
    @Test func theCheckCatchesAPageTooTallForTheWindow() {
        let tooTall = VStack(alignment: .leading, spacing: 40) {
            ForEach(0..<12) { KeyringText("Line \($0) of a page that is too tall for the setup window.", as: .title) }
        }
        let result = ScreenCheck.run(tooTall, on: KeyringScreen("light", size: CGSize(width: 534, height: 560), scrolls: false))
        #expect(result.findings.contains { if case .outside = $0 { true } else if case .notDrawn = $0 { true } else { false } }, "\(result.findings)")
    }
}

/// Checks each entry on each of its screens, writing pictures if asked.
@MainActor
func checkAll(_ entries: [KeyringGalleryEntry]) throws {
    let folder = ProcessInfo.processInfo.environment["KEYRING_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
    if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    for entry in entries {
        for screen in KeyringScreen.all(for: entry.kind) {
            let result = ScreenCheck.run(entry.view, on: screen)
            #expect(result.findings.isEmpty, "\(entry.id) (\(screen.name)):\n  \(result.findings.map(\.description).joined(separator: "\n  "))")
            #expect(!result.words.isEmpty, "\(entry.id) (\(screen.name)) reported no words: is it built from the parts?")
            guard let folder else { continue }
            let name = "\(platform)-\(entry.id)-\(screen.name)"
            if let image = result.image { try png(image, to: folder.appendingPathComponent(name + ".png")) }
            try (result.words.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        }
    }
}

private var platform: String {
    #if os(macOS)
    "mac"
    #elseif os(iOS)
    "iphone"
    #else
    "watch"
    #endif
}

private func png(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}
