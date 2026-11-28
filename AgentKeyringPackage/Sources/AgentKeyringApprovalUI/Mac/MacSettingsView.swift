// Written by AI on 2026.11.26 by model gemini-4-neon.
//
// Native macOS Settings window (⌘,) for app preferences, analytics, manual sync
// and reset, keeping the Devices tab focused on the user's devices.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

public struct MacSettingsView: View {
    @Bindable var model: MacMainModel

    public init(model: MacMainModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s4) {
            if model.snapshot.opensAtLogin != nil || model.snapshot.remindsToUpdate != nil {
                card {
                    if let opens = model.snapshot.opensAtLogin {
                        toggleRow(
                            title: MainWindowCopy.openAtLogin,
                            detail: MainWindowCopy.openAtLoginDetail,
                            isOn: Binding(get: { opens }, set: model.setOpensAtLogin)
                        )
                    }
                    if model.snapshot.opensAtLogin != nil && model.snapshot.remindsToUpdate != nil {
                        Divider()
                    }
                    if let reminds = model.snapshot.remindsToUpdate {
                        toggleRow(
                            title: MainWindowCopy.remindToUpdate,
                            detail: MainWindowCopy.remindToUpdateDetail,
                            isOn: Binding(get: { reminds }, set: model.setPasswordCopyReminder)
                        )
                    }
                }
            }

            card {
                toggleRow(
                    title: MainWindowCopy.anonymousTelemetry,
                    detail: MainWindowCopy.anonymousTelemetryDetail,
                    isOn: Binding(get: { model.snapshot.anonymousTelemetry }, set: model.setAnonymousTelemetry)
                )
            }

            card {
                KeyringDeviceRow(symbol: "arrow.triangle.2.circlepath", name: MainWindowCopy.syncTitle, detail: MainWindowCopy.syncNowDetail) {
                    KeyringButton(.plain(MainWindowCopy.syncNow, isEnabled: !model.isWorking) { model.syncWithICloudNow() })
                        .frame(width: 112)
                }
                .padding(.horizontal, KeyringSpace.s4)
                .padding(.vertical, KeyringSpace.s3)
                Divider()
                KeyringDeviceRow(symbol: "arrow.counterclockwise", name: MainWindowCopy.resetAppTitle, detail: MainWindowCopy.resetAppDetail) {
                    KeyringButton(.destructive(MainWindowCopy.resetApp, isEnabled: !model.isWorking) { model.askToReset() })
                        .frame(width: 112)
                }
                .padding(.horizontal, KeyringSpace.s4)
                .padding(.vertical, KeyringSpace.s3)
            }
        }
        .padding(KeyringSpace.s5)
        .frame(width: 520)
        .background(KeyringPalette.canvas)
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.followUpdates() }
        .confirmationDialog(
            MainWindowCopy.resetTitle,
            isPresented: Binding(
                get: { model.deviceDialog == .reset },
                set: { if !$0, model.deviceDialog == .reset { model.dismissDeviceDialog() } }
            )
        ) {
            Button(MainWindowCopy.resetThisMac, role: .destructive) { model.resetKeyring(includingICloud: false) }
            Button(MainWindowCopy.resetEverything, role: .destructive) { model.resetKeyring(includingICloud: true) }
            Button(MainWindowCopy.cancel, role: .cancel) { model.dismissDeviceDialog() }
        } message: {
            Text(MainWindowCopy.resetMessage)
        }
        .alert(
            MenuBarCopy.appName,
            isPresented: Binding(
                get: { model.failure != nil && model.deviceDialog == nil },
                set: { if !$0 { model.dismissFailure() } }
            )
        ) {
            Button(SetupCopy.ok) { model.dismissFailure() }
        } message: {
            Text(model.failure ?? "")
        }
    }

    private func toggleRow(title: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: KeyringSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                KeyringText(title, as: .body)
                if let detail {
                    KeyringText(detail, as: .meta)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn)
                .toggleStyle(KeyringMacSwitchStyle())
                .labelsHidden()
        }
        .padding(.horizontal, KeyringSpace.s4)
        .padding(.vertical, KeyringSpace.s3)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card))
            .clipShape(.rect(cornerRadius: KeyringRadius.card))
            .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card).strokeBorder(KeyringPalette.line))
    }
}

/// Native-proportioned switch tinted in KeyringPalette.brand so ON and OFF states remain
/// unmistakable even when the Settings window is inactive or rendered off-screen.
private struct KeyringMacSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(configuration.isOn ? KeyringPalette.brand : KeyringPalette.line)
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.16), radius: 1.5, y: 0.5)
                    .padding(2)
            }
            .animation(.easeInOut(duration: 0.14), value: configuration.isOn)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
#endif
