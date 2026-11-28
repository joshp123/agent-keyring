// Written by AI on 2026.11.25 by model gemini-4-neon; split into step views on 2026.11.27 by model claude opus 5.5.
//
// Selective Import steps that guide the user to export from Apple Passwords:
// 3A Pick a Few, 3B Pick Categories, and the 3B / 3C Export All bridge.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

// MARK: - 3A Pick a Few Passwords

struct MacImportPickFewStep: View {
    let state: MacSelectiveImportState
    let actions: MacSelectiveImportPageActions
    let guideStep: Int

    var body: some View {
        let clamped = min(max(guideStep, 1), SelectiveImportCopy.pickFewGuide.count)
        return MacImportStepPage {
            MacImportStepHeader(
                title: SelectiveImportCopy.pickFewTitle,
                subtitle: SelectiveImportCopy.pickFewSubtitle
            )
            exportGuideCard(clamped: clamped)
            manualAddCard

            KeyringText(SelectiveImportCopy.exportedByMistake, as: .caption)

            if let status = state.status {
                KeyringStatusLine(status)
            }
        } footer: {
            KeyringButton(.link(SelectiveImportCopy.addByCategoryInstead, perform: actions.switchToCategories))
            Spacer(minLength: KeyringSpace.s2)
            KeyringButton(.plain(FirstRunCopy.back, perform: actions.backToChoose))
            KeyringButton(.advance(SelectiveImportCopy.openApplePasswords, isEnabled: !state.isBusy, perform: actions.openApplePasswords))
        }
    }

    private func exportGuideCard(clamped: Int) -> some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s2) {
            HStack(alignment: .center) {
                KeyringText(SelectiveImportCopy.inApplePasswordsHeader, as: .sectionName)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Button {
                        if clamped > 1 { actions.showGuideStep(clamped - 1) }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 20)
                            .background(KeyringPalette.fill, in: .rect(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(KeyringPalette.line))
                    }
                    .buttonStyle(.plain)
                    .disabled(clamped <= 1)
                    .accessibilityLabel(FirstRunCopy.previous)

                    KeyringText(SelectiveImportCopy.guideCounter(clamped, total: SelectiveImportCopy.pickFewGuide.count), as: .caption)
                        .monospacedDigit()
                        .padding(.horizontal, 4)

                    Button {
                        if clamped < SelectiveImportCopy.pickFewGuide.count { actions.showGuideStep(clamped + 1) }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 20)
                            .background(KeyringPalette.surface, in: .rect(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(KeyringPalette.line))
                    }
                    .buttonStyle(.plain)
                    .disabled(clamped >= SelectiveImportCopy.pickFewGuide.count)
                    .accessibilityLabel(FirstRunCopy.next)
                }
            }

            KeyringText(SelectiveImportCopy.pickFewGuide[clamped - 1], as: .caption, colour: KeyringPalette.ink)
                .frame(minHeight: 32, alignment: .topLeading)

            PasswordsExportPicture(guideStep: clamped, items: 2)

            HStack {
                Spacer(minLength: 0)
                KeyringButton(.link(FirstRunCopy.notInList, perform: actions.notInList))
            }
        }
        .padding(KeyringSpace.s3)
        .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card))
        .clipShape(.rect(cornerRadius: KeyringRadius.card))
        .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card).strokeBorder(KeyringPalette.line))
    }

    private var manualAddCard: some View {
        HStack(alignment: .center, spacing: KeyringSpace.s3) {
            VStack(alignment: .leading, spacing: 1) {
                KeyringText(SelectiveImportCopy.manualAddHeading, as: .label, colour: KeyringPalette.ink)
                KeyringText(SelectiveImportCopy.manualAddDetail, as: .caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            KeyringButton(.link(SelectiveImportCopy.addManually, perform: actions.openManualAdd))
        }
        .padding(.horizontal, KeyringSpace.s3)
        .padding(.vertical, 9)
        .background(KeyringPalette.fill, in: .rect(cornerRadius: KeyringRadius.card))
        .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card).strokeBorder(KeyringPalette.line))
    }
}

// MARK: - 3B Pick Categories

struct MacImportCategoriesStep: View {
    let state: MacSelectiveImportState
    let actions: MacSelectiveImportPageActions

    var body: some View {
        MacImportStepPage {
            MacImportStepHeader(
                title: SelectiveImportCopy.categoriesTitle,
                subtitle: SelectiveImportCopy.categoriesSubtitle
            )

            VStack(spacing: 0) {
                ForEach(Array(MacImportCategoryOption.defaults.enumerated()), id: \.element.id) { index, option in
                    if index > 0 { Divider() }
                    categoryRow(option)
                }
            }
            .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card))
            .clipShape(.rect(cornerRadius: KeyringRadius.card))
            .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card).strokeBorder(KeyringPalette.line))

            KeyringText(SelectiveImportCopy.categoriesFootnote, as: .caption)

            if let status = state.status {
                KeyringStatusLine(status)
            }
        } footer: {
            KeyringButton(.link(SelectiveImportCopy.pickFewInstead, perform: actions.switchToPickFew))
            KeyringButton(.link(SelectiveImportCopy.addAllInstead, perform: actions.switchToAllPasswords))
            Spacer(minLength: KeyringSpace.s2)
            KeyringButton(.plain(FirstRunCopy.back, perform: actions.backToChoose))
            KeyringButton(.advance(
                FirstRunCopy.continueButton,
                isEnabled: !state.selectedCategories.isEmpty,
                perform: actions.continueFromCategories
            ))
        }
    }

    private func categoryRow(_ option: MacImportCategoryOption) -> some View {
        let checked = state.selectedCategories.contains(option.id)
        return Button {
            actions.toggleCategory(option.id)
        } label: {
            HStack(alignment: .center, spacing: KeyringSpace.s3) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(checked ? KeyringPalette.brand : KeyringPalette.ink3)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    KeyringText(option.title, as: .label, colour: KeyringPalette.ink)
                    KeyringText(option.examples, as: .caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    ForEach(option.exampleDomains, id: \.self) { domain in
                        SiteIconView(host: domain, size: 19)
                    }
                }
            }
            .padding(.horizontal, KeyringSpace.s3)
            .padding(.vertical, 6)
            .background(checked ? KeyringPalette.brandTint.opacity(0.55) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 3B / 3C Export All Bridge

struct MacImportExportBridgeStep: View {
    let state: MacSelectiveImportState
    let actions: MacSelectiveImportPageActions
    let selectedCategoryTitles: [String]
    let isAllPasswords: Bool

    var body: some View {
        let explanation = isAllPasswords
            ? SelectiveImportCopy.whyExportAllAllBody
            : SelectiveImportCopy.whyExportAllCategoryBody(selectedCategoryTitles)

        return MacImportStepPage {
            MacImportStepHeader(title: SelectiveImportCopy.exportBridgeTitle, subtitle: nil)

            VStack(alignment: .leading, spacing: KeyringSpace.s2) {
                KeyringText(SelectiveImportCopy.whyExportAllHeading, as: .label, colour: KeyringPalette.ink)
                KeyringText(explanation, as: .caption)
                KeyringText(SelectiveImportCopy.whyExportAllGuarantee, as: .caption)
            }
            .padding(KeyringSpace.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card))
            .clipShape(.rect(cornerRadius: KeyringRadius.card))
            .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card).strokeBorder(KeyringPalette.line))

            HStack(alignment: .center, spacing: KeyringSpace.s4) {
                VStack(alignment: .leading, spacing: 5) {
                    KeyringText(SelectiveImportCopy.inApplePasswordsTitle, as: .label, colour: KeyringPalette.ink)
                    ForEach(SelectiveImportCopy.exportAllSteps, id: \.self) { stepText in
                        KeyringText(stepText, as: .caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                PasswordsExportAllMenuPicture()
            }
            .padding(KeyringSpace.s3)
            .background(KeyringPalette.fill, in: .rect(cornerRadius: KeyringRadius.card))

            HStack {
                Spacer(minLength: 0)
                KeyringButton(.link(FirstRunCopy.notInList, perform: actions.notInList))
            }

            if let status = state.status {
                KeyringStatusLine(status)
            }
        } footer: {
            KeyringButton(.link(SelectiveImportCopy.pickFewInstead, perform: actions.switchToPickFew))
            Spacer(minLength: KeyringSpace.s2)
            KeyringButton(.plain(FirstRunCopy.back, perform: isAllPasswords ? actions.backToChoose : actions.backToCategories))
            KeyringButton(.advance(SelectiveImportCopy.openApplePasswords, isEnabled: !state.isBusy, perform: actions.openApplePasswords))
        }
    }
}
#endif
