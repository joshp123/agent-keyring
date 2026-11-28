// Written by AI on 2026.11.23 by model claude opus 5.5.
//
// The iPhone as a vault of its own: copying from Passwords on this iPhone, and
// adding another computer with a one-time code. Built only from
// AgentKeyringDesign's parts; every word comes from PhoneCopy.

#if os(iOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

/// "Copy your passwords": turn Agent Keyring on in Passwords, then export from Passwords to it.
struct PhoneCopyPasswordsPage: View {
    let model: PhoneModel
    let inFirstRun: Bool

    var body: some View {
        let copy = model.snapshot.passwordsCopy
        let status: KeyringStatus? = copy.copying ? .waiting(PhoneCopy.copyingNow)
            : copy.problem.map(KeyringStatus.problem) ?? (copy.turnedOn ? .waiting(PhoneCopy.copyWaiting) : nil)
        KeyringPage(step: inFirstRun ? (1, 3) : nil, title: PhoneCopy.copyTitle, sentence: PhoneCopy.copyLead, status: status,
                    primary: copy.turnedOn ? nil : .advance(PhoneCopy.turnOnInPasswords) { Task { _ = await model.turnOnInPasswords() } },
                    secondary: inFirstRun ? .link(PhoneCopy.skipForNow) { Task { await model.sendFirstRunEvent(.passwordsImported) } } : nil) {
            KeyringSteps(PhoneCopy.copySteps)
            if copy.turnedOn { KeyringConfirmation(PhoneCopy.turnedOnInPasswords) }
            KeyringHint(symbol: "lock.fill", PhoneCopy.otherDevicesGetCopies, tone: .plain)
        }
        .task { _ = await model.turnOnInPasswords(asking: false) }
    }
}

/// "Add another computer": the code and its command, then the computer's request, approved with Face ID.
struct PhoneAddComputerPage: View {
    let model: PhoneModel

    var body: some View {
        PhoneAddComputerContent(state: model.snapshot.addComputer) { tap in Task { await model.handleAddComputerTap(tap) } }
            .onAppear { Task { await model.handleAddComputerTap(.open) } }
            .onDisappear { Task { await model.handleAddComputerTap(.close) } }
    }
}

/// Unified progress/waiting card used across iPhone receiving, Watch encrypting, and computer pairing states.
struct PhoneProgressCard: View {
    let symbol: String
    let title: String
    var done: Int? = nil
    var total: Int? = nil
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s3) {
            HStack(spacing: KeyringSpace.s3) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(KeyringPalette.brand)
                    .frame(width: 36, height: 36)
                    .background(KeyringPalette.brandTint, in: .rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    KeyringText(title, as: .heading)
                    if let footnote {
                        KeyringText(footnote, as: .meta)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if done == nil || total == nil {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let done, let total, total > 0 {
                ProgressView(value: Double(min(done, total)), total: Double(total))
                    .tint(KeyringPalette.brand)
            }
        }
        .padding(KeyringSpace.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card, style: .continuous).strokeBorder(KeyringPalette.line))
    }
}

/// One page per state of adding a computer.
struct PhoneAddComputerContent: View {
    let state: PhoneAddComputer?
    let tap: (PhoneAddComputerTap) -> Void

    var body: some View {
        switch state {
        case let .invite(_, command, until)?:
            KeyringPage(title: PhoneCopy.addComputerTitle, sentence: PhoneCopy.addComputerLead) {
                KeyringCopyBlock(text: command, monospaced: true)
                ShareLink(item: command) {
                    Label(PhoneCopy.shareCommand, systemImage: "square.and.arrow.up")
                        .font(KeyringFont.fixed(KeyringFont.PostScript.medium, size: 15))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(KeyringPalette.brand)
                PhoneProgressCard(
                    symbol: "desktopcomputer",
                    title: PhoneCopy.waitingForComputer(until: until)
                )
            }
        case let .asked(name)?:
            KeyringPage(title: PhoneCopy.computerAsks(name), sentence: PhoneCopy.computerAsksDetail,
                        primary: .approve(PhoneCopy.approveWithFaceID) { tap(.approve) },
                        secondary: .plain(PhoneCopy.dontAdd) { tap(.deny) })
        case let .adding(name)?:
            KeyringPage(title: PhoneCopy.addComputerTitle, status: .waiting(PhoneCopy.adding(name)))
        case let .added(name)?:
            KeyringPage(title: PhoneCopy.computerAdded(name), sentence: PhoneCopy.computerAddedDetail, alignment: .centre, mascot: .approved)
        case let .notAdded(name)?:
            KeyringPage(title: PhoneCopy.addComputerTitle, status: .problem(PhoneCopy.computerNotAdded(name)),
                        primary: .advance(PhoneCopy.newCode) { tap(.newCode) })
        case .expired?:
            KeyringPage(title: PhoneCopy.addComputerTitle, status: .problem(PhoneCopy.codeExpired),
                        primary: .advance(PhoneCopy.newCode) { tap(.newCode) })
        case let .failed(reason)?:
            KeyringPage(title: PhoneCopy.addComputerTitle, status: .problem(reason),
                        primary: .advance(PhoneCopy.newCode) { tap(.newCode) })
        case let .deliveryFailed(_, reason)?:
            KeyringPage(title: PhoneCopy.addComputerTitle, status: .problem(reason),
                        primary: .advance(PhoneCopy.tryAgain) { tap(.retryDelivery) },
                        secondary: .plain(PhoneCopy.newCode) { tap(.newCode) })
        case nil:
            KeyringPage(title: PhoneCopy.addComputerTitle, sentence: PhoneCopy.addComputerLead)
        }
    }
}

#endif
