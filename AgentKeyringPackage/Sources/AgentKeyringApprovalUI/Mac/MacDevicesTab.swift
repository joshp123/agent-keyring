// Written by AI on 2026.11.21 by model claude opus 5.5, from the Paper page
// "Agent Keyring (Holistic)", board 3 ("Mac: Devices"), and the copy ledger.
//
// Devices: where he approves password requests, and the other computers
// whose agents can ask. Every row is read from the members list as it is
// now; what stops this Mac reaching them is said above the lists.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

public struct MacDevicesTab: View {
    @Bindable var model: MacMainModel

    public init(model: MacMainModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KeyringSpace.s4) {
                KeyringText(MainWindowCopy.devicesTab, as: .title)

                // Touch ID was cancelled after a copy, or sending failed: the way to send them now.
                if model.snapshot.unsentChanges > 0 {
                    card {
                        KeyringDeviceRow(symbol: "arrow.triangle.2.circlepath", name: MainWindowCopy.unsentChanges(model.snapshot.unsentChanges),
                                         detail: MainWindowCopy.unsentChangesDetail, tone: .needsDoing) {
                            KeyringButton(.plain(MainWindowCopy.sendUpdates, perform: model.sendUnsentChanges))
                        }
                        .padding(.horizontal, KeyringSpace.s4)
                        .padding(.vertical, KeyringSpace.s3)
                    }
                }

                if !model.snapshot.notices.isEmpty {
                    card {
                        VStack(alignment: .leading, spacing: KeyringSpace.s2) {
                            ForEach(model.snapshot.notices, id: \.self) { KeyringStatusLine(.takingLong(Self.words($0))) }
                        }
                        .padding(.horizontal, KeyringSpace.s4)
                        .padding(.vertical, KeyringSpace.s3)
                    }
                }

                VStack(alignment: .leading, spacing: KeyringSpace.s2) {
                    KeyringText(MainWindowCopy.whereYouApprove, as: .sectionName)
                    card {
                        ForEach(Array(model.snapshot.approvers.enumerated()), id: \.element.id) { index, approver in
                            if index > 0 { Divider() }
                            KeyringDeviceRow(symbol: Self.symbol(approver.kind), name: Self.name(approver), detail: Self.detail(approver),
                                             tone: Self.tone(approver)) {
                                HStack(spacing: KeyringSpace.s2) {
                                    KeyringButton(.plain(MainWindowCopy.sendPractice, isEnabled: approver.canPractise) { model.sendPracticeRequest(approver.id) })
                                        .fixedSize()
                                    // Reserve the trailing 24pt slot on thisMac so every Practice button aligns vertically.
                                    if approver.kind != .thisMac {
                                        Menu {
                                            Button(MainWindowCopy.rename) {
                                                model.askToRename(approver.id, name: approver.name)
                                            }
                                            Button(MainWindowCopy.remove, role: .destructive) {
                                                model.askToRemove(approver.id, name: approver.name, isComputer: false)
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                                .font(.system(size: 16))
                                                .foregroundStyle(KeyringPalette.ink2)
                                        }
                                        .menuStyle(.borderlessButton)
                                        .menuIndicator(.hidden)
                                        .frame(width: 24, height: 24)
                                        .disabled(model.isWorking)
                                        .accessibilityLabel(MainWindowCopy.moreActions)
                                    } else {
                                        Color.clear
                                            .frame(width: 24, height: 24)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .fixedSize()
                            }
                            .padding(.horizontal, KeyringSpace.s4)
                            .padding(.vertical, KeyringSpace.s3)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: KeyringSpace.s2) {
                    KeyringText(MainWindowCopy.otherComputers, as: .sectionName)
                    card {
                        if model.snapshot.computers.isEmpty {
                            KeyringText(MainWindowCopy.noOtherComputers, as: .meta)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, KeyringSpace.s4)
                                .padding(.vertical, KeyringSpace.s3)
                        } else {
                            ForEach(Array(model.snapshot.computers.enumerated()), id: \.element.id) { index, computer in
                                if index > 0 { Divider() }
                                KeyringDeviceRow(symbol: "desktopcomputer", name: computer.name) {
                                    Menu {
                                        Button(MainWindowCopy.rename) {
                                            model.askToRename(computer.id, name: computer.name)
                                        }
                                        Button(MainWindowCopy.remove, role: .destructive) {
                                            model.askToRemove(computer.id, name: computer.name, isComputer: true)
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                            .font(.system(size: 16))
                                            .foregroundStyle(KeyringPalette.ink2)
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .frame(width: 24, height: 24)
                                    .disabled(model.isWorking)
                                    .accessibilityLabel(MainWindowCopy.moreActions)
                                }
                                .padding(.horizontal, KeyringSpace.s4)
                                .padding(.vertical, KeyringSpace.s3)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, KeyringSpace.s6)
            .padding(.vertical, KeyringSpace.s5)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(KeyringPalette.canvas)
        .alert(MainWindowCopy.renameTitle,
               isPresented: Binding(get: { if case .rename = model.deviceDialog { true } else { false } },
                                    set: { if !$0, case .rename = model.deviceDialog { model.dismissDeviceDialog() } })) {
            TextField(MainWindowCopy.renameField, text: $model.renameDraft)
            Button(MainWindowCopy.save) { model.commitRename() }
            Button(MainWindowCopy.cancel, role: .cancel) { model.dismissDeviceDialog() }
        }
        .confirmationDialog(removeTitle,
            isPresented: Binding(get: { if case .remove = model.deviceDialog { true } else { false } },
                                 set: { if !$0, case .remove = model.deviceDialog { model.dismissDeviceDialog() } })) {
            Button(MainWindowCopy.removeConfirm, role: .destructive) {
                if case let .remove(id, _, _) = model.deviceDialog { model.removeDevice(id) }
            }
            Button(MainWindowCopy.cancel, role: .cancel) { model.dismissDeviceDialog() }
        } message: {
            if case let .remove(id, name, isComputer) = model.deviceDialog {
                let alsoAsks = model.snapshot.approvers.first { $0.id == id }?.alsoAsks == true
                Text(isComputer ? MainWindowCopy.removeComputer(name) : alsoAsks ? MainWindowCopy.removeMac(name) : MainWindowCopy.removeDevice(name))
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card))
            .clipShape(.rect(cornerRadius: KeyringRadius.card))
            .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card).strokeBorder(KeyringPalette.line))
    }

    private var removeTitle: String {
        if case let .remove(_, name, _) = model.deviceDialog { return MainWindowCopy.removeTitle(name) }
        return MainWindowCopy.removeTitle("")
    }

    static func words(_ notice: DevicesNotice) -> String {
        switch notice {
        case .noICloud: MessageCopy.noICloud
        case .noPushKey: MessageCopy.noPushKey
        }
    }

    static func symbol(_ kind: ApproverDeviceKind) -> String {
        switch kind {
        case .thisMac, .mac: "laptopcomputer"
        case .iPhone: "iphone"
        case .watch: "applewatch"
        }
    }

    static func name(_ approver: ApproverRow) -> String {
        approver.kind == .thisMac ? MainWindowCopy.thisMacName(approver.name) : approver.name
    }

    /// How it approves; readiness when setup isn't finished, or practice progress when running.
    static func detail(_ approver: ApproverRow) -> String {
        switch approver.readiness {
        case .waitingForNotifications:
            return MessageCopy.noPushAddress(approver.name)
        case let .syncingCopies(done, total):
            return SetupCopy.copyingTo(done: done, total: total)
        case .unavailable:
            return AccessRequestCopy.noApprover
        case .ready:
            break
        }
        return switch approver.practice {
        case nil:
            switch approver.kind {
            case .thisMac: MainWindowCopy.macAnswers
            case .iPhone: MainWindowCopy.phoneAnswers
            case .watch: MainWindowCopy.watchAnswers
            case .mac: MainWindowCopy.otherMacAnswers
            }
        case .waitingHere?: MainWindowCopy.practiceHere
        case .sending?: MainWindowCopy.practiceSending
        case .withApple?: MainWindowCopy.practiceSent(toWatch: approver.kind == .watch)
        case .approved?: MainWindowCopy.practiceApproved
        case .denied?: MainWindowCopy.practiceDenied
        case .noAnswer?: MainWindowCopy.practiceNoAnswer
        case let .failed(sentence)?: sentence
        }
    }

    static func tone(_ approver: ApproverRow) -> KeyringDeviceRowTone {
        switch approver.readiness {
        case .waitingForNotifications, .unavailable: return .needsDoing
        case .syncingCopies: return .waiting
        case .ready: break
        }
        switch approver.practice {
        case nil, .noAnswer?: return .plain
        case .waitingHere?, .sending?, .withApple?: return .waiting
        case .failed?: return .needsDoing
        case .approved?: return .approved
        case .denied?: return .denied
        }
    }
}
extension DevicesSnapshot {
    /// The Mac's rows: this Mac first, then every other device he approves on.
    public func macApprovers(thisMac: ApproverRow, readiness: (SignedListApprover) -> DeviceReadiness,
                             practice: (SignedListApprover) -> PracticeStatus?) -> [ApproverRow] {
        [thisMac] + approvers.filter { $0.id != thisMac.id }.map { approver in
            let ready = readiness(approver)
            let practice = practice(approver)
            let kind: ApproverDeviceKind = switch approver.device.kind {
            case .iPhone: .iPhone
            case .watch: .watch
            case .mac: .mac
            }
            // This Mac pushes practice requests to iPhones and Watches; another Mac is not sent one.
            return ApproverRow(id: approver.id, kind: kind, name: approver.device.name, practice: practice,
                               canPractise: kind != .mac && ready == .ready && practice?.isUnderWay != true,
                               readiness: ready, alsoAsks: approver.alsoAsks)
        }
    }
}
#endif
