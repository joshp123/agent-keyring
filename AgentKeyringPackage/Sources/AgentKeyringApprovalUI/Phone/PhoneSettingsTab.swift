// Written by AI on 2026.11.18 by model Claude Opus 5.5; rebuilt on 2026.11.26
// by model gemini-4-neon; split into its own file on 2026.11.27 by model claude opus 5.5.
//
// Settings: native Form as the 4th tab (or modal fallback) + Quiet Hours +
// Sync + Reset dialog.

#if os(iOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

/// Settings on iPhone: native Form as 4th tab (or modal fallback) + blue switches + Quiet Hours + Sync + Reset dialog.
struct PhoneSettingsView: View {
    let model: PhoneModel
    var inTab: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        let settings = model.snapshot.settings
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: binding(\.timeSensitive)) { KeyringText(PhoneCopy.timeSensitive) }
                } footer: { KeyringText(PhoneCopy.timeSensitiveDetail, as: .caption) }
                .listRowBackground(KeyringPalette.surface)

                Section {
                    Toggle(isOn: binding(\.quietHours)) { KeyringText(PhoneCopy.quietHours) }
                        .disabled(!settings.timeSensitive)
                    if settings.quietHours && settings.timeSensitive {
                        DatePicker(selection: time(\.quietFrom), displayedComponents: .hourAndMinute) { KeyringText(PhoneCopy.from) }
                        DatePicker(selection: time(\.quietTo), displayedComponents: .hourAndMinute) { KeyringText(PhoneCopy.to) }
                    }
                } footer: {
                    KeyringText(PhoneCopy.quietHoursDetail, as: .caption)
                }
                .listRowBackground(KeyringPalette.surface)

                Section {
                    Toggle(isOn: binding(\.remindToUpdate)) { KeyringText(PhoneCopy.remindToUpdate) }
                } footer: {
                    KeyringText(PhoneCopy.remindToUpdateDetail, as: .caption)
                }
                .listRowBackground(KeyringPalette.surface)

                Section {
                    Toggle(isOn: binding(\.anonymousTelemetry)) { KeyringText(PhoneCopy.anonymousTelemetry) }
                } footer: { KeyringText(PhoneCopy.anonymousTelemetryDetail, as: .caption) }
                .listRowBackground(KeyringPalette.surface)

                Section {
                    Button(model.isSyncing ? PhoneCopy.syncingNow : PhoneCopy.syncNow) {
                        Task { await model.syncWithICloudNow() }
                    }
                    .disabled(model.isSyncing || model.isResetting)
                    Button(PhoneCopy.resetApp, role: .destructive) { confirmReset = true }
                        .disabled(model.isResetting)
                }
                .listRowBackground(KeyringPalette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(KeyringPalette.canvas)
            .navigationTitle(PhoneCopy.settings)
            .navigationBarTitleDisplayMode(inTab ? .large : .inline)
            .toolbar {
                if !inTab {
                    ToolbarItem(placement: .topBarTrailing) { Button(PhoneCopy.done) { dismiss() } }
                }
            }
            .confirmationDialog(PhoneCopy.resetTitle, isPresented: $confirmReset, titleVisibility: .visible) {
                Button(PhoneCopy.resetThisIPhone, role: .destructive) {
                    Task { await model.resetKeyring(includingICloud: false) }
                }
                Button(PhoneCopy.resetEverything, role: .destructive) {
                    Task { await model.resetKeyring(includingICloud: true) }
                }
                Button(PhoneCopy.cancel, role: .cancel) {}
            } message: {
                Text(PhoneCopy.resetDetail)
            }
        }
        .tint(KeyringPalette.brand)
        .environment(\.locale, Locale(identifier: "en_GB"))
    }

    private func binding(_ path: WritableKeyPath<PhoneSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.snapshot.settings[keyPath: path] }, set: { value in
            var next = model.snapshot.settings
            next[keyPath: path] = value
            Task { await model.savePhoneSettings(next) }
        })
    }

    private func time(_ path: WritableKeyPath<PhoneSettings, Int>) -> Binding<Date> {
        let calendar = Calendar.current
        return Binding(get: {
            calendar.date(bySettingHour: model.snapshot.settings[keyPath: path] / 60, minute: model.snapshot.settings[keyPath: path] % 60,
                          second: 0, of: .now) ?? .now
        }, set: { date in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            var next = model.snapshot.settings
            next[keyPath: path] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            Task { await model.savePhoneSettings(next) }
        })
    }
}
#endif
