// Written by AI on 2026.11.20 by model claude opus 5.5; rebuilt on 2026.11.21
// by the same model for the four local steps and the device sheets.
//
// Maps first run's saved state, a copy from Passwords, iCloud and the Mac's
// joins to the plain values the pages draw (AgentKeyringApprovalUI,
// MacSetupPages.swift and MacDeviceSheets.swift), and wires their buttons.
// Every value is read from where it lives, each time a page is drawn.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import AgentKeyringDesign
import AgentKeyringEngine
import AgentKeyringProtocol
import AppKit
import Foundation
import SwiftUI

@available(macOS 26.0, *)
@MainActor
public enum SetupScreens {
    /// The page before first run, while this Mac's keys wait for him; nil once they are made.
    public static func thisMac(_ setup: MacHardwareSetupFlow) -> ThisMacPageState? {
        switch setup {
        case .loading, .ready: nil
        case .askHowUsed: .askHowUsed
        case .forAgents: .forAgents
        case let .personalMac(failure): .personalMac(failure: failure)
        case .noSecureEnclave: .noSecureEnclave
        case let .keysFailed(reason): .keysFailed(reason)
        }
    }

    /// Welcome's offer to join the list on his iPhone, while this Mac has none of its own.
    public static func welcomeIPhone(_ model: MacKeyringEngine) -> MacWelcomePage.IPhone? {
        switch model.device?.joiningIPhone {
        case nil: nil
        case let .found(name)?: .found(name: name)
        case let .asking(name)?: .asking(name: name)
        case let .notAdded(name)?: .notAdded(name: name)
        case let .joined(name)?: .joined(name: name)
        }
    }

    /// Practice as step 1 draws it.
    public static func practicePageState(_ practice: MacFirstRunPracticeState) -> MacPracticePageState {
        switch practice {
        case .notSent: .notSent
        case .waiting: .waiting
        case .approved: .approved
        case let .denied(reply): .denied(reply: reply)
        }
    }

    /// His own passwords are in the list, not only the test password.
    public static func copiedCount(_ model: MacKeyringEngine) -> Int? {
        guard let status = model.status, status.sampleOnly != true else { return nil }
        // The list always holds the one test password beside his own.
        return max(status.credentialItemCount - 1, 0)
    }

    /// Maps live selective-import state from `MacKeyringEngine` into the plain value `MacSelectiveImportPage` draws.
    public static func selectiveImport(_ model: MacKeyringEngine, inFirstRun: Bool) -> MacSelectiveImportState {
        let session = model.importSession
        let status = selectiveImportStatus(session, model: model)
        if inFirstRun, let joined = joinedDeviceImport(model, status: status) { return joined }
        return MacSelectiveImportState(
            step: selectiveImportStep(session),
            chosenPath: session.path,
            selectedCategories: session.selectedCategories,
            status: status,
            isBusy: session.exportState == .copying || session.isSaving,
            inFirstRun: inFirstRun
        )
    }

    private static func selectiveImportStatus(_ session: SelectiveImportSession, model: MacKeyringEngine) -> KeyringStatus? {
        switch session.exportState {
        case .copying:
            .waiting(FirstRunCopy.copying)
        case .noneArrived:
            .takingLong(FirstRunCopy.noneArrived)
        case .idle, .waiting, .allowExport:
            (session.problem ?? model.problem).map(KeyringStatus.problem)
        }
    }

    /// Joined another device's list during first run: derive synced/syncing state from persisted
    /// Members + Catalogue instead of ephemeral joiningIPhone, never showing interactive .choose while copying.
    private static func joinedDeviceImport(_ model: MacKeyringEngine, status: KeyringStatus?) -> MacSelectiveImportState? {
        let session = model.importSession
        guard let device = model.device,
              device.hasMembers,
              session.step == .choose,
              session.staged == nil else { return nil }
        let peerName: String = if case let .joined(name)? = device.joiningIPhone {
            name
        } else {
            device.members?.devices.first(where: {
                $0.keyID != device.ownDeviceID && ($0.kind == .iphone || $0.kind == .mac)
            })?.label ?? "your other device"
        }
        if let catalogue = device.catalogue {
            let count = catalogue.logins.filter(\.holdsSecret).count
            if device.ownCopiesHeld >= count {
                return MacSelectiveImportState(
                    step: .syncedFromDevice(count: count, from: peerName),
                    chosenPath: session.path,
                    selectedCategories: session.selectedCategories,
                    status: status,
                    isBusy: false,
                    inFirstRun: true
                )
            }
        }
        return MacSelectiveImportState(
            step: .syncingFromDevice(from: peerName),
            chosenPath: session.path,
            selectedCategories: session.selectedCategories,
            status: .waiting(FirstRunCopy.copying),
            isBusy: true,
            inFirstRun: true
        )
    }

    private static func selectiveImportStep(_ session: SelectiveImportSession) -> MacSelectiveImportStep {
        switch session.step {
        case .choose:
            return .choose
        case .pickFew:
            return .pickFew(guideStep: session.guideStep)
        case .pickCategories:
            return .pickCategories
        case .exportBridge:
            let titles = ImportCategory.selectableCases
                .filter { session.selectedCategories.contains($0) }
                .map { MacImportCategoryOption.title(for: $0) }
            return .exportBridge(
                selectedCategoryTitles: titles,
                isAllPasswords: session.path == .allPasswords
            )
        case .review:
            guard let staged = session.staged else { return .choose }
            return reviewImportStep(staged, isSaving: session.isSaving)
        case let .receipt(receipt):
            return .receipt(MacImportReceiptData(
                filteredCount: receipt.filteredCount,
                savedCount: receipt.savedCount,
                notSavedCount: receipt.notSavedCount,
                savedSites: receipt.savedSites.map { MacImportReceiptSite(displayName: $0.displayName, host: $0.host) },
                isReimport: receipt.isReimport
            ))
        }
    }

    private static func reviewImportStep(_ staged: StagedImport, isSaving: Bool) -> MacSelectiveImportStep {
        let rows = staged.items.map { item in
            MacReviewPasswordRow(
                id: item.id,
                displayName: item.displayName,
                host: item.host,
                account: item.account,
                categoryLabel: item.category.flatMap {
                    switch $0 {
                    case .other: nil
                    case .sensitive: SelectiveImportCopy.categorySensitiveLabel
                    default: MacImportCategoryOption.title(for: $0)
                    }
                },
                isSelected: staged.isSelected(item),
                isSensitive: item.isSensitive
            )
        }
        return .review(
            items: rows,
            isCategoryMode: staged.path == .byCategory,
            sensitiveExcludedCount: staged.excludedSensitiveItems.count,
            sensitiveExcludedExamples: staged.groupedExcludedSensitiveNames,
            isSaving: isSaving,
            sortingRemainingCount: staged.sortingRemainingCount
        )
    }

    public static func connectAgent(_ outcome: FirstAgentRequestOutcome) -> MacConnectAgentOutcome {
        switch outcome {
        case .notTried: .notTried
        case let .worked(agent): .worked(agent: agent)
        case let .denied(agent): .denied(agent: agent)
        }
    }

    public static func readyCopied(_ model: MacKeyringEngine) -> SetupCopiedSummary {
        copiedCount(model).map(SetupCopiedSummary.passwords) ?? .testPasswordOnly
    }

    /// Each row on Ready, from the members list as it is now.
    public static func readyDevices(_ model: MacKeyringEngine) -> SetupDevicesSummary {
        let device = model.device
        let devices = device?.members?.devices ?? []
        let filling = device?.filling?.deviceKeyID
        return SetupDevicesSummary(
            iPhone: devices.first { $0.kind == .iphone && $0.keyID != filling }?.label,
            watch: devices.first { $0.kind == .watch }?.label,
            computers: (device?.members?.machines ?? []).filter { $0.machineID != device?.ownMachineID }.map(\.label))
    }

    // MARK: The device sheets

    /// "Add your iPhone". `opened`: when the sheet opened, so only an iPhone added or refused since then counts.
    public static func addIPhone(_ model: MacKeyringEngine, opened: Date, known: Set<String>) -> MacAddIPhoneSheetState {
        guard let device = model.device else { return .problem(MessageCopy.noKeysYet) }
        // The iPhone joins through iCloud.
        switch device.cloudState {
        case .signedOut, .failed: return .noICloud
        case .starting, .syncing: break
        }
        let listed = Dictionary((device.members?.devices ?? []).map { ($0.keyID, $0.kind) }, uniquingKeysWith: { first, _ in first })
        if let filling = device.filling, listed[filling.deviceKeyID] == .iphone, !known.contains(filling.deviceKeyID) {
            if let failure = filling.failure {
                return .stopped(name: filling.label, done: filling.done, total: filling.total, reason: failure)
            }
            return .copying(name: filling.label, done: filling.done, total: filling.total)
        }
        if let added = device.members?.devices.first(where: { $0.kind == .iphone && !known.contains($0.keyID) }) {
            return .added(name: added.label)
        }
        let phones = device.joinHistory.filter { $0.joiner == .device(.iphone) }
        if let asking = phones.first(where: { $0.state == .waiting }) { return .joinAsked(name: asking.label) }
        let refused = phones.first.flatMap { $0.asked >= opened && [.refused, .expired, .withdrawn].contains($0.state) ? $0.label : nil }
        return .waiting(notAdded: refused)
    }

    /// The iPhones already added when the sheet opens: adding another is still possible.
    public static func knownIPhones(_ model: MacKeyringEngine) -> Set<String> {
        Set((model.device?.members?.devices ?? []).filter { $0.kind == .iphone }.map(\.keyID))
    }

    /// "Add another computer", for the code the sheet holds: the join comes through boxes at the relay.
    public static func addComputer(_ model: MacKeyringEngine, invite: MacSyncCoordinator.MachineInvite?, now: Date) -> MacAddComputerSheetState {
        guard let device = model.device, let invite else { return .starting }
        let joins = device.joinHistory.filter { $0.joiner == .computer && $0.secret == invite.secret }
        if joins.contains(where: { $0.state == .withdrawn }) { return .withdrawn }
        if let join = joins.first {
            switch join.state {
            case .waiting: return .joinAsked(name: join.label)
            case .approved: return .added(name: join.label)
            case .refused: return .notAdded(name: join.label)
            default: return .expired
            }
        }
        if invite.expires <= now { return .expired }
        return .invite(command: DeviceSheetCopy.enrolCommand(invite.code.enrolArgument), until: AccessRequestCopy.clock(invite.expires))
    }
}

/// "Add your iPhone" in a sheet, from Ready or Devices. It holds only when it opened and which iPhones were there.
@available(macOS 26.0, *)
public struct AddIPhoneSheet: View {
    let model: MacKeyringEngine
    let close: () -> Void
    @State private var opened = Date()
    @State private var known: Set<String>

    public init(model: MacKeyringEngine, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        _known = State(initialValue: SetupScreens.knownIPhones(model))
    }

    public var body: some View {
        MacAddIPhoneSheet(SetupScreens.addIPhone(model, opened: opened, known: known),
                          checkAgain: { model.device?.cloudChanged() }, close: close)
            .onAppear { model.device?.leaveInvitationForIPhone() }
            .onChange(of: model.device?.cloudState) { model.device?.leaveInvitationForIPhone() }
    }
}

/// "Add another computer" in a sheet. It holds the invite it made, and a new one on Create New Invite.
@available(macOS 26.0, *)
public struct AddComputerSheet: View {
    let model: MacKeyringEngine
    let close: () -> Void
    @State private var invite: MacSyncCoordinator.MachineInvite?

    public init(model: MacKeyringEngine, close: @escaping () -> Void) {
        self.model = model
        self.close = close
    }

    public var body: some View {
        // Drawn again when the invite runs out, so Expired shows on time. The
        // timeline's own date is the entry's (the expiry, even on the first
        // draw), so the clock is read here.
        TimelineView(.explicit(invite.map { [$0.expires, $0.expires.addingTimeInterval(1)] } ?? [])) { _ in
            MacAddComputerSheet(SetupScreens.addComputer(model, invite: invite, now: .now), actions: actions)
        }
        .onAppear { if invite == nil { makeInvite() } }
        .onChange(of: model.device == nil) { if invite == nil { makeInvite() } }
        .onDisappear { if let invite { model.device?.withdrawCode(invite) } }
    }

    private var actions: MacAddComputerSheetActions {
        var actions = MacAddComputerSheetActions()
        actions.newInvite = makeInvite
        actions.close = close
        return actions
    }

    private func makeInvite() {
        if let invite { model.device?.withdrawCode(invite) }
        invite = try? model.device?.machineInvite()
    }
}
#endif
