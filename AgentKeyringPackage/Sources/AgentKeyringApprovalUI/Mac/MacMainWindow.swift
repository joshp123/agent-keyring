// Written by AI on 2026.11.18 by model claude opus 5.5; rebuilt on 2026.11.26
// by model gemini-4-neon with 3-destination sidebar + Settings… ⌘, + full-width
// reactive mascot. Rows, snapshot and backend are in MainWindowContracts.swift,
// the model in MacMainModel.swift and Activity in MacActivityTab.swift.

#if os(macOS)
import AppKit
import AgentKeyringApprovalCore
import AgentKeyringDesign
import Observation
import SwiftUI

/// The main Mac window: clean 3-destination sidebar (Activity, Passwords, Devices) + Settings… ⌘, + full-width mascot.
public struct MacMainWindowView: View {
    private enum WindowSheet: String, Identifiable {
        case addIPhone, addComputer, addPassword
        var id: String { rawValue }
    }

    @Bindable var model: MacMainModel
    let sheetContent: (DevicesSheet, @escaping () -> Void) -> AnyView
    let onOpenSettings: (() -> Void)?
    let initialReplyingRequestID: String?
    let initialReplyDraft: String
    @Environment(\.openSettings) private var openSettings
    @State private var sheet: WindowSheet?

    public init(
        model: MacMainModel,
        onOpenSettings: (() -> Void)? = nil,
        initialReplyingRequestID: String? = nil,
        initialReplyDraft: String = "",
        sheet: @escaping (DevicesSheet, @escaping () -> Void) -> AnyView
    ) {
        self.model = model
        self.onOpenSettings = onOpenSettings
        self.initialReplyingRequestID = initialReplyingRequestID
        self.initialReplyDraft = initialReplyDraft
        self.sheetContent = sheet
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .background(KeyringPalette.canvas)
        .toolbar {
            if model.destination == .passwords {
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.isEditingRules {
                        Button("Done") {
                            model.endEditingRules()
                        }
                    } else {
                        Button {
                            sheet = .addPassword
                        } label: {
                            Label(MainWindowCopy.addPassword, systemImage: "plus")
                        }
                        .labelStyle(.titleAndIcon)
                        .keyboardShortcut("n", modifiers: .command)

                        Button {
                            model.importAgain()
                        } label: {
                            Label(MainWindowCopy.copyFromPasswords, systemImage: "square.and.arrow.down")
                        }
                        .labelStyle(.titleAndIcon)

                        Button {
                            model.beginEditingRules()
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .labelStyle(.titleAndIcon)
                    }
                }
            } else if model.destination == .devices {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(MainWindowCopy.addIPhone) { sheet = .addIPhone }
                        Button(MainWindowCopy.addComputer) { sheet = .addComputer }
                    } label: {
                        Label(MainWindowCopy.addDevice, systemImage: "plus")
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
        }
        .navigationTitle(windowTitle)
        .onChange(of: model.destination) { _, _ in model.dismissDeviceDialog() }
        .sheet(item: $sheet) { which in
            switch which {
            case .addIPhone: sheetContent(.addIPhone) { sheet = nil }
            case .addComputer: sheetContent(.addComputer) { sheet = nil }
            case .addPassword:
                MacAddPasswordSheet(
                    onSave: { site, account, password, totp, rule in
                        try await model.addManualPassword(website: site, account: account, password: password, totpSecret: totp, rule: rule)
                    },
                    onCancel: { sheet = nil }
                )
            }
        }
        .sheet(item: $model.ruleConfirmation) { confirmation in
            MacRuleConfirmSheet(
                confirmation: confirmation,
                computers: model.snapshot.computers.map(\.name),
                isWorking: model.isWorking,
                onCancel: { model.cancelRuleChange() },
                onConfirm: { model.confirmRuleChange() }
            )
        }
        .task { await model.followUpdates() }
        .alert(MenuBarCopy.appName, isPresented: Binding(get: { model.failure != nil && model.deviceDialog == nil }, set: { if !$0 { model.dismissFailure() } })) {
            Button(SetupCopy.ok) { model.dismissFailure() }
        } message: { Text(model.failure ?? "") }
    }

    private var windowTitle: String {
        switch model.destination {
        case .activity: MainWindowCopy.activityTab
        case .passwords: MainWindowCopy.passwordsTab
        case .devices: MainWindowCopy.devicesTab
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                sidebarItem(
                    title: MainWindowCopy.activityTab,
                    symbol: "clock.fill",
                    tint: model.waitingCount > 0 ? KeyringPalette.brand : KeyringPalette.ink2,
                    count: model.waitingCount > 0 ? model.waitingCount : nil,
                    highlightCount: model.waitingCount > 0,
                    selected: model.destination == .activity
                ) { model.destination = .activity }

                sidebarItem(
                    title: MainWindowCopy.passwordsTab,
                    symbol: "key.fill",
                    tint: KeyringPalette.ink2,
                    count: model.loginCount(nil),
                    selected: model.destination == .passwords
                ) { model.destination = .passwords }

                sidebarItem(
                    title: MainWindowCopy.devicesTab,
                    symbol: "laptopcomputer.and.iphone",
                    tint: KeyringPalette.ink2,
                    count: model.snapshot.approvers.count + model.snapshot.computers.count,
                    selected: model.destination == .devices
                ) { model.destination = .devices }
            }
            .padding(.horizontal, KeyringSpace.s2)
            .padding(.top, KeyringSpace.s3)

            Spacer(minLength: 0)

            Button {
                if let onOpenSettings { onOpenSettings() } else { openSettings() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(KeyringPalette.ink2)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    KeyringText("Settings…", as: .body, colour: KeyringPalette.ink2)
                    Spacer(minLength: 4)
                    KeyringText("⌘,", as: .meta, colour: KeyringPalette.ink3)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, KeyringSpace.s2)
            .padding(.bottom, KeyringSpace.s2)

            Divider()

            VStack(spacing: 0) {
                KeyringMascot(model.mascotMood)
                    .frame(width: 148, height: 148)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, KeyringSpace.s4)
        }
        .frame(width: 204)
        .background(KeyringPalette.sidebar)
    }

    private func sidebarItem(
        title: String,
        symbol: String,
        tint: Color = KeyringPalette.ink2,
        count: Int?,
        highlightCount: Bool = false,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? KeyringPalette.brand : tint)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                KeyringText(title, as: selected ? .heading : .body, colour: selected ? KeyringPalette.brand : KeyringPalette.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    KeyringText(
                        count.formatted(),
                        as: .meta,
                        colour: highlightCount ? KeyringPalette.brand : KeyringPalette.ink2
                    )
                    .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? KeyringPalette.brandTint : Color.clear, in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var detail: some View {
        switch model.destination {
        case .activity: MacActivityTab(model: model, initialReplyingRequestID: initialReplyingRequestID, initialReplyDraft: initialReplyDraft)
        case .passwords: MacPasswordsTab(model: model)
        case .devices: MacDevicesTab(model: model)
        }
    }
}
#endif
