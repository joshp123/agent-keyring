// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The things you set once and check when something is wrong: passwords on
// this iPhone, the Agent Keyring it talks to, when requests reach the phone,
// and this phone's key.

#if os(iOS)
import SwiftUI

struct PhoneSettingsView: View {
    let model: PhoneKeyringModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { PhoneImportView(model: model) } label: { passwordsRow }
                } header: {
                    Text(SetupCopy.phonePasswordsTitle)
                } footer: {
                    Text(SetupCopy.phonePasswordsFooter)
                }

                Section {
                    if model.pairing == .paired {
                        connectionRow
                    } else {
                        NavigationLink(SetupCopy.pairTitle) { PhonePairingView(model: model) }
                    }
                    if let rulesUpdatedAt = model.settings.rulesUpdatedAt {
                        LabeledContent("Rules", value: "Checked \(rulesUpdatedAt.formatted(.relative(presentation: .named)))")
                    }
                    if let delay = model.settings.askPhoneAfter {
                        LabeledContent(SetupCopy.macAsksPhoneAfter, value: SetupCopy.delay(delay))
                    }
                } header: {
                    Text("Requests")
                } footer: {
                    Text(SetupCopy.phoneDelayFooter)
                }

                Section {
                    LabeledContent("Notifications", value: SetupCopy.notifications(model.settings.notifications))
                    LabeledContent("Key") {
                        Text(model.settings.keyFingerprint)
                            .font(.footnote.monospaced())
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("This iPhone")
                } footer: {
                    Text("Your approvals are signed with this key, which never leaves the iPhone's Secure Enclave.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .tint(KeyringColour.signal)
    }

    @ViewBuilder private var passwordsRow: some View {
        switch model.passwords {
        case let .imported(count, at):
            LabeledContent("\(count) logins on this iPhone", value: "Updated \(at.formatted(.relative(presentation: .named)))")
        case let .importing(received):
            LabeledContent("Importing", value: "\(received) so far")
        case .notImported:
            LabeledContent("None", value: "Optional")
        case .importFailed:
            LabeledContent("Last import didn't finish") { Text("See why").foregroundStyle(KeyringColour.denyText) }
        }
    }

    @ViewBuilder private var connectionRow: some View {
        switch model.connection {
        case let .connected(service, lastContact):
            LabeledContent("Agent Keyring on \(service)",
                value: "Connected \(AccessRequestCopy.clock(lastContact))")
        case let .unreachable(service, since):
            LabeledContent("Agent Keyring on \(service)") {
                Text("Unreachable since \(AccessRequestCopy.clock(since))").foregroundStyle(KeyringColour.denyText)
            }
        case .notPaired:
            LabeledContent("Not paired", value: "")
        }
    }

}
#endif
