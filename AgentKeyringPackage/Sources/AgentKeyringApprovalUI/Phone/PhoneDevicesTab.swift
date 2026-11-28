// Written by AI on 2026.11.18 by model Claude Opus 5.5; rebuilt on 2026.11.26
// by model gemini-4-neon; split into its own file on 2026.11.27 by model claude opus 5.5.
//
// Devices tab: native insetGrouped sections, neutral Practice pills matching
// Mac, idiomatic Add rows inside sections.

#if os(iOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

/// Devices: native insetGrouped sections, neutral Practice pills matching Mac, idiomatic Add rows inside sections.
struct PhoneDevicesView: View {
    let model: PhoneModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var removing: PhoneDevice?

    var body: some View {
        PhoneList(title: PhoneCopy.devices) {
            // Another device changed the list while apart: the merged list is sent from here, Mac or no Mac.
            if model.snapshot.hasUnsentUpdates {
                Section {
                    Button {
                        Task { await model.sendUnsentChanges() }
                    } label: {
                        KeyringText(MainWindowCopy.sendUpdates, as: .body, colour: KeyringPalette.brand)
                    }
                    .disabled(model.isChangingRuleOrDevice)
                } header: {
                    KeyringText(MainWindowCopy.unsentChanges(1), as: .sectionName)
                } footer: {
                    KeyringText(MainWindowCopy.unsentChangesDetail, as: .caption)
                }
                .listRowBackground(KeyringPalette.surface)
            }
            Section {
                ForEach(model.snapshot.devices.filter { $0.role == .approves }) { deviceRow($0) }
                if model.snapshot.watch.toAdd {
                    Button {
                        Task { await model.handleAddWatchTap(.open) }
                    } label: {
                        KeyringText(PhoneCopy.addAppleWatchRow, as: .body, colour: KeyringPalette.brand)
                    }
                }
            } header: { KeyringText(PhoneCopy.youApproveOn, as: .sectionName) }
            .listRowBackground(KeyringPalette.surface)

            let computers = model.snapshot.devices.filter { $0.role == .asks }
            Section {
                ForEach(computers) { deviceRow($0) }
                NavigationLink { PhoneAddComputerPage(model: model) } label: {
                    KeyringText(PhoneCopy.addComputerRow, colour: KeyringPalette.brand)
                }
            } header: {
                KeyringText(PhoneCopy.agentsAskFrom, as: .sectionName)
            } footer: {
                KeyringText(PhoneCopy.agentComputersFooter, as: .caption)
            }
            .listRowBackground(KeyringPalette.surface)
        }
        .confirmationDialog(removing.map { PhoneCopy.removeQuestion($0.name) } ?? "", isPresented: removingShown,
                            titleVisibility: .visible, presenting: removing) { device in
            Button(PhoneCopy.remove, role: .destructive) { Task { await model.removeDevice(device: device.id) } }
            Button(PhoneCopy.cancel, role: .cancel) {}
        } message: { device in Text(PhoneCopy.removeDetail(device, alsoAsks: device.alsoAsks)) }
        .onChange(of: model.tab) { _, tab in
            if tab != .devices { removing = nil }
        }
        .onChange(of: model.sheet.item) { _, item in
            if item != nil { removing = nil }
        }
    }

    @ViewBuilder private func deviceRow(_ device: PhoneDevice) -> some View {
        let isWarning = device.readiness == .waitingForNotifications || device.readiness == .unavailable
        let rowDetail = detailText(device)
        let rowColour = detailColour(device)
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: KeyringSpace.s2) {
                    HStack(alignment: .center, spacing: KeyringSpace.s3) {
                        Image(systemName: symbol(device))
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(isWarning ? KeyringPalette.stalled : KeyringPalette.ink2)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        KeyringText(device.isThisIPhone ? PhoneCopy.thisIPhone : device.name, as: .heading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if device.role == .approves, let rowDetail, !rowDetail.isEmpty {
                        KeyringText(rowDetail, as: .meta, colour: rowColour)
                    }
                    if device.canPractice {
                        practicePill(device)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: KeyringSpace.s3) {
                    Image(systemName: symbol(device))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isWarning ? KeyringPalette.stalled : KeyringPalette.ink2)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        KeyringText(device.isThisIPhone ? PhoneCopy.thisIPhone : device.name, as: .heading)
                        if device.role == .approves, let rowDetail, !rowDetail.isEmpty {
                            KeyringText(rowDetail, as: .meta, colour: rowColour)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if device.canPractice {
                        practicePill(device)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        .swipeActions(edge: .trailing) {
            if device.canRemove && !device.isThisIPhone && !model.isChangingRuleOrDevice {
                Button(PhoneCopy.remove, role: .destructive) { removing = device }
            }
        }
    }

    private func practicePill(_ device: PhoneDevice) -> some View {
        Button {
            Task { await model.sendPracticeRequest(to: device.isThisIPhone ? nil : device.id) }
        } label: {
            KeyringText(PhoneCopy.practiceShort, as: .meta, colour: KeyringPalette.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(KeyringPalette.fill, in: Capsule(style: .circular))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func symbol(_ device: PhoneDevice) -> String {
        switch device.kind {
        case .iPhone: "iphone"
        case .watch: "applewatch"
        case .mac: "laptopcomputer"
        case .computer: "desktopcomputer"
        }
    }

    private func detailText(_ device: PhoneDevice) -> String? {
        guard device.role == .approves else { return nil }
        switch device.readiness {
        case .waitingForNotifications:
            return MessageCopy.noPushAddress(device.name)
        case let .syncingCopies(done, total):
            return total > 0 ? SetupCopy.copyingTo(done: done, total: total) : device.detail
        case .unavailable:
            return AccessRequestCopy.noApprover
        case .ready:
            break
        }
        switch device.practice {
        case nil:
            switch device.kind {
            case .iPhone: return PhoneCopy.answersWithFaceID
            case .watch: return PhoneCopy.answersWithTap
            case .mac: return PhoneCopy.answersWithTouchID
            case .computer: return nil
            }
        case .waitingHere?, .sending?, .withApple?:
            return PhoneCopy.practiceWaiting
        case .approved?:
            return PhoneCopy.practiceResult(.approved)
        case .denied?:
            return PhoneCopy.practiceResult(.denied)
        case .noAnswer?:
            return PhoneCopy.practiceResult(.noAnswer)
        case let .failed(sentence)?:
            return sentence
        }
    }

    private func detailColour(_ device: PhoneDevice) -> Color {
        switch device.readiness {
        case .waitingForNotifications, .unavailable:
            return KeyringPalette.stalled
        case .syncingCopies:
            return KeyringPalette.ink2
        case .ready:
            break
        }
        switch device.practice {
        case .approved?: return KeyringPalette.approve
        case .denied?: return KeyringPalette.deny
        case .failed?: return KeyringPalette.stalled
        case nil, .waitingHere?, .sending?, .withApple?, .noAnswer?: return KeyringPalette.ink2
        }
    }

    private var removingShown: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }
}
#endif
