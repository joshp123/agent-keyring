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
        Form {
            // After Not Now on sending changes: the way to send them later.
            if model.snapshot.unsentChanges > 0 {
                Section {
                    KeyringDeviceRow(symbol: "arrow.triangle.2.circlepath", name: MainWindowCopy.unsentChanges(model.snapshot.unsentChanges),
                                     detail: MainWindowCopy.unsentChangesDetail, tone: .needsDoing) {
                        KeyringButton(.plain(MainWindowCopy.sendUpdates, perform: model.sendUpdates))
                    }
                }
            }
            if !model.snapshot.notices.isEmpty {
                Section {
                    ForEach(model.snapshot.notices, id: \.self) { KeyringStatusLine(.takingLong(Self.words($0))) }
                }
            }
            Section {
                ForEach(model.snapshot.approvers) { approver in
                    KeyringDeviceRow(symbol: Self.symbol(approver.kind), name: Self.name(approver), detail: Self.detail(approver),
                                     tone: Self.tone(approver.practice)) {
                        HStack(spacing: KeyringSpace.s2) {
                            KeyringButton(.plain(MainWindowCopy.sendPractice, isEnabled: approver.canPractise) { model.sendPractice(approver.id) })
                            if approver.kind != .thisMac {
                                KeyringButton(.plain(MainWindowCopy.rename, isEnabled: !model.isWorking) {
                                    model.askToRename(approver.id, name: approver.name)
                                })
                                KeyringButton(.plain(MainWindowCopy.remove, isEnabled: !model.isWorking) {
                                    model.askToRemove(approver.id, name: approver.name, isComputer: false)
                                })
                            }
                        }
                        // The row's control is one button; two side by side would share its width and cut each other off.
                        .fixedSize()
                    }
                }
            } header: {
                KeyringText(MainWindowCopy.whereYouApprove, as: .sectionName)
            }
            Section {
                if model.snapshot.computers.isEmpty {
                    KeyringText(MainWindowCopy.noOtherComputers, as: .meta)
                }
                ForEach(model.snapshot.computers) { computer in
                    KeyringDeviceRow(symbol: "desktopcomputer", name: computer.name) {
                        HStack(spacing: KeyringSpace.s2) {
                            KeyringButton(.plain(MainWindowCopy.rename, isEnabled: !model.isWorking) {
                                model.askToRename(computer.id, name: computer.name)
                            })
                            KeyringButton(.plain(MainWindowCopy.remove, isEnabled: !model.isWorking) {
                                model.askToRemove(computer.id, name: computer.name, isComputer: true)
                            })
                        }
                        .fixedSize()
                    }
                }
            } header: {
                KeyringText(MainWindowCopy.otherComputers, as: .sectionName)
            }
        }
        .formStyle(.grouped)
        .alert(MainWindowCopy.renameTitle,
               isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })) {
            TextField(MainWindowCopy.renameField, text: $model.renameDraft)
            Button(MainWindowCopy.save) { model.commitRename() }
            Button(MainWindowCopy.cancel, role: .cancel) { model.renaming = nil }
        }
        .confirmationDialog(MainWindowCopy.removeTitle(model.removing?.name ?? ""),
            isPresented: Binding(get: { model.removing != nil }, set: { if !$0 { model.removing = nil } })) {
            Button(MainWindowCopy.removeConfirm, role: .destructive) { if let id = model.removing?.id { model.remove(id) } }
            Button(MainWindowCopy.cancel, role: .cancel) { model.removing = nil }
        } message: {
            if let removing = model.removing {
                Text(removing.isComputer ? MainWindowCopy.removeComputer(removing.name) : MainWindowCopy.removeDevice(removing.name))
            }
        }
    }

    static func words(_ notice: DoorNotice) -> String {
        switch notice {
        case .noTailscale: MessageCopy.noTailscale
        case .noPushKey: MessageCopy.noPushKey
        case .failed: MainWindowCopy.doorFailed
        }
    }

    static func symbol(_ kind: ApproverRow.Kind) -> String {
        switch kind {
        case .thisMac: "laptopcomputer"
        case .iPhone: "iphone"
        case .watch: "applewatch"
        }
    }

    static func name(_ approver: ApproverRow) -> String {
        approver.kind == .thisMac ? MainWindowCopy.thisMacName(approver.name) : approver.name
    }

    /// How it approves; while a practice request is under way or just answered, where that is up to.
    static func detail(_ approver: ApproverRow) -> String {
        switch approver.practice {
        case nil:
            switch approver.kind {
            case .thisMac: MainWindowCopy.macAnswers
            case .iPhone: MainWindowCopy.phoneAnswers
            case .watch: MainWindowCopy.watchAnswers
            }
        case .waitingHere?: MainWindowCopy.practiceHere
        case .sending?: MainWindowCopy.practiceSending
        case .withApple?: MainWindowCopy.practiceWithApple
        case .arrived?: approver.kind == .watch ? MainWindowCopy.practiceOnWatch : MainWindowCopy.practiceOnPhone
        case .approved?: MainWindowCopy.practiceApproved
        case .denied?: MainWindowCopy.practiceDenied
        case .noAnswer?: MainWindowCopy.practiceNoAnswer
        case let .failed(sentence)?: sentence
        }
    }

    static func tone<Trailing>(_ practice: PracticeStatus?) -> KeyringDeviceRow<Trailing>.Tone {
        switch practice {
        case nil, .noAnswer?: .plain
        case .waitingHere?, .sending?, .withApple?, .arrived?: .waiting
        case .approved?: .approved
        case .denied?, .failed?: .denied
        }
    }
}
#endif
