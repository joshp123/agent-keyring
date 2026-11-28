// Written by AI on 2026.11.25 by model gemini-4-neon; split into step views on 2026.11.27 by model claude opus 5.5.
//
// Production macOS page for Step 3 (Selective Import), also shown from the main
// window. Each step is its own view; this page picks one from the state. Built
// on AgentKeyringDesign's tokens and text/button primitives so NothingIsCutOff
// audits every screen automatically.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

public struct MacSelectiveImportPageActions {
    public var selectPath: (ImportPath) -> Void = { _ in }
    public var continueFromChoose: () -> Void = {}
    public var skipForNow: () -> Void = {}
    public var backToPreviousSetupStep: () -> Void = {}
    public var cancelFlow: () -> Void = {}

    public var showGuideStep: (Int) -> Void = { _ in }
    public var openApplePasswords: () -> Void = {}
    public var notInList: () -> Void = {}
    public var openManualAdd: () -> Void = {}
    public var switchToCategories: () -> Void = {}
    public var switchToPickFew: () -> Void = {}
    public var switchToAllPasswords: () -> Void = {}

    public var toggleCategory: (ImportCategory) -> Void = { _ in }
    public var continueFromCategories: () -> Void = {}
    public var backToChoose: () -> Void = {}
    public var backToCategories: () -> Void = {}

    public var toggleReviewItem: (UUID) -> Void = { _ in }
    public var includeAllSensitive: () -> Void = {}
    public var excludeAllSensitive: () -> Void = {}
    public var changeCategories: () -> Void = {}
    public var cancelImport: () -> Void = {}
    public var saveSelected: () -> Void = {}

    public var addMorePasswords: () -> Void = {}
    public var finishStep: () -> Void = {}

    public init() {}
}

public struct MacSelectiveImportPage: View {

    let state: MacSelectiveImportState
    let actions: MacSelectiveImportPageActions

    public init(_ state: MacSelectiveImportState, actions: MacSelectiveImportPageActions = MacSelectiveImportPageActions()) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        if state.inFirstRun {
            MacFirstRunWindow(step: 3, mascot: mascotMood) {
                contentBody
            }
        } else {
            contentBody
                .frame(width: KeyringSize.macWindow.width - KeyringSize.macSidebar, height: KeyringSize.macWindow.height)
        }
    }

    private var mascotMood: KeyringMascotMood {
        switch state.step {
        case .receipt, .syncedFromDevice:
            return .approved
        case .choose, .pickFew, .pickCategories, .exportBridge, .review, .syncingFromDevice:
            if case .takingLong = state.status { return .waiting }
            return .calm
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        switch state.step {
        case .choose:
            MacImportChooseStep(state: state, actions: actions)
        case let .pickFew(guideStep):
            MacImportPickFewStep(state: state, actions: actions, guideStep: guideStep)
        case .pickCategories:
            MacImportCategoriesStep(state: state, actions: actions)
        case let .exportBridge(selectedCategoryTitles, isAllPasswords):
            MacImportExportBridgeStep(
                state: state,
                actions: actions,
                selectedCategoryTitles: selectedCategoryTitles,
                isAllPasswords: isAllPasswords
            )
        case let .review(items, isCategoryMode, sensitiveExcludedCount, _, isSaving, sortingRemainingCount):
            MacImportReviewStep(
                state: state,
                actions: actions,
                review: MacImportReviewContent(
                    items: items,
                    isCategoryMode: isCategoryMode,
                    sensitiveExcludedCount: sensitiveExcludedCount,
                    isSaving: isSaving,
                    sortingRemainingCount: sortingRemainingCount
                )
            )
        case let .receipt(receipt):
            MacImportReceiptStep(state: state, actions: actions, receipt: receipt)
        case let .syncingFromDevice(from):
            MacImportDeviceSyncingStep(actions: actions, deviceName: from)
        case let .syncedFromDevice(count, from):
            MacImportDeviceSyncedStep(actions: actions, count: count, deviceName: from)
        }
    }
}

// MARK: - 3.1 Choose Starting Point

struct MacImportChooseStep: View {
    let state: MacSelectiveImportState
    let actions: MacSelectiveImportPageActions

    var body: some View {
        MacImportStepPage {
            MacImportStepHeader(
                title: SelectiveImportCopy.chooseTitle,
                subtitle: SelectiveImportCopy.chooseSubtitle
            )

            VStack(spacing: 0) {
                choiceRow(
                    choice: .pickFew,
                    title: SelectiveImportCopy.pathFewTitle,
                    detail: SelectiveImportCopy.pathFewDetail
                )
                Divider()
                choiceRow(
                    choice: .byCategory,
                    title: SelectiveImportCopy.pathCategoryTitle,
                    detail: SelectiveImportCopy.pathCategoryDetail
                )
                Divider()
                choiceRow(
                    choice: .allPasswords,
                    title: SelectiveImportCopy.pathAllTitle,
                    detail: SelectiveImportCopy.pathAllDetail
                )
            }
            .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card))
            .clipShape(.rect(cornerRadius: KeyringRadius.card))
            .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card).strokeBorder(KeyringPalette.line))

            HStack(spacing: KeyringSpace.s2) {
                KeyringText(SelectiveImportCopy.chooseNote, as: .caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, KeyringSpace.s3)
            .padding(.vertical, KeyringSpace.s2)
            .background(KeyringPalette.fill, in: .rect(cornerRadius: 9, style: .continuous))

            if let status = state.status {
                KeyringStatusLine(status)
            }
        } footer: {
            if state.inFirstRun {
                KeyringButton(.link(SelectiveImportCopy.skipForNow, perform: actions.skipForNow))
            }
            Spacer(minLength: KeyringSpace.s2)
            if state.inFirstRun {
                KeyringButton(.plain(FirstRunCopy.back, perform: actions.backToPreviousSetupStep))
            } else {
                KeyringButton(.plain(FirstRunCopy.cancel, perform: actions.cancelFlow))
            }
            KeyringButton(.advance(FirstRunCopy.continueButton, perform: actions.continueFromChoose))
        }
    }

    private func choiceRow(choice: ImportPath, title: String, detail: String) -> some View {
        let selected = state.chosenPath == choice
        return Button {
            actions.selectPath(choice)
        } label: {
            HStack(alignment: .top, spacing: KeyringSpace.s3) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? KeyringPalette.brand : KeyringPalette.ink3)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    KeyringText(title, as: .label, colour: KeyringPalette.ink)
                    KeyringText(detail, as: .caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, KeyringSpace.s4)
            .padding(.vertical, 13)
            .background(selected ? KeyringPalette.brandTint.opacity(0.6) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared page chrome

/// The title and optional subtitle at the top of every Selective Import step.
struct MacImportStepHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s1) {
            KeyringText(title, as: .title)
            if let subtitle {
                KeyringText(subtitle, as: .meta)
            }
        }
    }
}

/// The padded page every Selective Import step sits in, with its button row at the bottom.
struct MacImportStepPage<Content: View, Footer: View>: View {
    let scrollBody: Bool
    let content: Content
    let footer: Footer

    init(
        scrollBody: Bool = true,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.scrollBody = scrollBody
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s3) {
            content
            if scrollBody {
                Spacer(minLength: 0)
            }
            Divider()
            HStack(spacing: KeyringSpace.s2) {
                footer
            }
        }
        .padding(.horizontal, KeyringSpace.s8)
        .padding(.top, KeyringSpace.s6)
        .padding(.bottom, KeyringSpace.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KeyringPalette.canvas)
    }
}
#endif
