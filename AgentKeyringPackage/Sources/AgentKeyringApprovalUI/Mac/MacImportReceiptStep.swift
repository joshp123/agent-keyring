// Written by AI on 2026.11.25 by model gemini-4-neon; split into step views on 2026.11.27 by model claude opus 5.5.
//
// Selective Import end states: the saved receipt, and syncing from (or synced
// from) another device that joined during setup.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

// MARK: - Saved Receipt

struct MacImportReceiptStep: View {
    let state: MacSelectiveImportState
    let actions: MacSelectiveImportPageActions
    let receipt: MacImportReceiptData

    var body: some View {
        MacImportStepPage {
            MacImportStepHeader(
                title: SelectiveImportCopy.receiptTitle(receipt.savedCount),
                subtitle: SelectiveImportCopy.receiptSubtitle
            )

            HStack(spacing: 0) {
                receiptStat(value: receipt.filteredCount, label: SelectiveImportCopy.receiptFilteredLabel, colour: KeyringPalette.ink)
                Divider().frame(height: 36)
                receiptStat(value: receipt.savedCount, label: SelectiveImportCopy.receiptSavedLabel, colour: KeyringPalette.approve)
                Divider().frame(height: 36)
                receiptStat(value: receipt.notSavedCount, label: SelectiveImportCopy.receiptNotSavedLabel, colour: KeyringPalette.ink2)
            }
            .padding(.vertical, KeyringSpace.s3)
            .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card))
            .clipShape(.rect(cornerRadius: KeyringRadius.card))
            .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card).strokeBorder(KeyringPalette.line))

            if !receipt.savedSites.isEmpty && receipt.savedSites.count <= 12 {
                savedSiteChips
            }

            VStack(alignment: .leading, spacing: KeyringSpace.s2) {
                KeyringText(SelectiveImportCopy.receiptStorageNote(saved: receipt.savedCount, notSaved: receipt.notSavedCount, isReimport: receipt.isReimport), as: .caption, colour: KeyringPalette.ink)
                KeyringText(state.inFirstRun ? SelectiveImportCopy.receiptApprovalNoteFirstRun : SelectiveImportCopy.receiptApprovalNoteMain, as: .caption)
            }
            .padding(KeyringSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KeyringPalette.fill, in: .rect(cornerRadius: KeyringRadius.card))
        } footer: {
            KeyringButton(.link(SelectiveImportCopy.addMorePasswords, perform: actions.addMorePasswords))
            Spacer(minLength: KeyringSpace.s2)
            KeyringButton(.advance(
                state.inFirstRun ? SelectiveImportCopy.connectAnAgent : SelectiveImportCopy.done,
                perform: actions.finishStep
            ))
        }
    }

    private var savedSiteChips: some View {
        let shownSites = Array(receipt.savedSites.prefix(4))
        let extraSites = max(receipt.savedCount - shownSites.count, 0)
        return VStack(alignment: .leading, spacing: KeyringSpace.s2) {
            KeyringText(SelectiveImportCopy.savedPasswordsHeading, as: .sectionName)
            HStack(spacing: 6) {
                ForEach(Array(shownSites.enumerated()), id: \.offset) { _, site in
                    HStack(spacing: 5) {
                        SiteIconView(host: site.host, displayName: site.displayName, size: 16)
                        KeyringText(site.displayName, as: .caption, colour: KeyringPalette.ink)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(KeyringPalette.surface, in: .capsule)
                    .overlay(Capsule().strokeBorder(KeyringPalette.line))
                    .frame(maxWidth: 135, alignment: .leading)
                }
                if extraSites > 0 {
                    KeyringText(SelectiveImportCopy.moreSaved(extraSites), as: .caption)
                        .fixedSize()
                }
            }
        }
    }

    private func receiptStat(value: Int, label: String, colour: Color) -> some View {
        VStack(spacing: 2) {
            KeyringText(value.formatted(), as: .title, colour: colour)
                .monospacedDigit()
            KeyringText(label, as: .caption)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Syncing / Synced from another device (joined iPhone during setup)

struct MacImportDeviceSyncingStep: View {
    let actions: MacSelectiveImportPageActions
    let deviceName: String

    var body: some View {
        MacImportStepPage {
            MacImportStepHeader(title: FirstRunCopy.copyTitle, subtitle: nil)
            KeyringStatusLine(.waiting(FirstRunCopy.connectedDetail(deviceName)))
        } footer: {
            Spacer(minLength: 0)
            KeyringButton(.plain(FirstRunCopy.back, perform: actions.backToPreviousSetupStep))
        }
    }
}

struct MacImportDeviceSyncedStep: View {
    let actions: MacSelectiveImportPageActions
    let count: Int
    let deviceName: String

    var body: some View {
        MacImportStepPage {
            MacImportStepHeader(title: FirstRunCopy.copyTitle, subtitle: nil)
            KeyringConfirmation(FirstRunCopy.syncedHeadline(count, from: deviceName), detail: FirstRunCopy.syncedDetail(count), tone: .approved)
        } footer: {
            Spacer(minLength: 0)
            KeyringButton(.plain(FirstRunCopy.back, perform: actions.backToPreviousSetupStep))
            KeyringButton(.advance(FirstRunCopy.continueButton, perform: actions.finishStep))
        }
    }
}
#endif
