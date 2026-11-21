// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Every page built from the parts, in each state worth seeing, with the
// longest words it will hold. The package test NothingIsCutOff hosts each
// entry at the device's smallest size and fails on anything cut off; with
// KEYRING_RENDER_DIR set it also draws each one to a PNG. Add a page here
// as soon as it exists (docs/design/page-parts.md).

import AgentKeyringDesign
import SwiftUI

@MainActor
public enum PageGallery {
    public static var entries: [KeyringGalleryEntry] {
#if os(macOS)
        [
            // The panel whose green button was cut off at "Click here, then touch the sen…".
            .init("question-panel-send-copied-passwords", .macPanel(width: 380)) {
                MacQuestionPanelView(title: SetupCopy.sendImportedTitle, message: SetupCopy.sendImportedBody,
                    approval: OwnerApproval(action: SetupCopy.sendImportedReason, reason: SetupCopy.sendImportedReason,
                        perform: { _ in }, finish: { _ in }))
            },
        ] + MacEverydayGallery.entries
        #elseif os(iOS)
        PhoneGallery.entries
        #else
        []
        #endif
    }
}
