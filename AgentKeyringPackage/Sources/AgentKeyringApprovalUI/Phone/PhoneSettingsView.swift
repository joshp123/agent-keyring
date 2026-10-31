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

    private static let delays: [Duration] = [.seconds(30), .seconds(60), .seconds(120), .seconds(300), .seconds(600)]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    passwordsRow
                } header: {
                    Text("Passwords on this iPhone")
                } footer: {
                    Text("After you add or change a password, export again: in the Passwords app, tap ··· then Export Data to Another App, and choose Agent Keyring.")
                }

                Section {
                    connectionRow
                    Picker("Ask this iPhone after", selection: askAfter) {
                        ForEach(Self.delays, id: \.self) { delay in
                            Text(delayText(delay)).tag(delay)
                        }
                    }
                } header: {
                    Text("Requests")
                } footer: {
                    Text("A request shows on your Mac first. If you don't answer there, it comes here after this delay.")
                }

                Section {
                    LabeledContent("Notifications", value: model.settings.notificationsAllowed ? "On" : "Off")
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
            LabeledContent("\(count) logins", value: "Imported \(at.formatted(.relative(presentation: .named)))")
        case let .importing(received):
            LabeledContent("Importing", value: "\(received) so far")
        case .notImported:
            LabeledContent("No passwords yet", value: "")
        case .importFailed:
            LabeledContent("Last import failed", value: "")
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

    private var askAfter: Binding<Duration> {
        Binding(get: { model.settings.askPhoneAfter },
            set: { delay in Task { await model.setAskPhoneAfter(delay) } })
    }

    private func delayText(_ delay: Duration) -> String {
        let seconds = Int(delay.components.seconds)
        return seconds < 60 ? "\(seconds) seconds" : seconds == 60 ? "1 minute" : "\(seconds / 60) minutes"
    }
}
#endif
