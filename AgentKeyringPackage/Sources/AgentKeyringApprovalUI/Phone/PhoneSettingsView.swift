// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The things you set once and check when something is wrong: the Agent
// Keyring this iPhone talks to, when requests reach it, and its key.

#if os(iOS)
import SwiftUI

struct PhoneSettingsView: View {
    let model: PhoneKeyringModel
    @Environment(\.dismiss) private var dismiss
    /// Value-based, so the pairing screen stays open while pairing moves the
    /// phone out of the paired state that showed "Pair again".
    @State private var path: [SettingsDestination] = []

    private enum SettingsDestination: Hashable {
        case pairing
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    if model.pairing == .paired {
                        connectionRow
                    } else {
                        NavigationLink(SetupCopy.pairTitle, value: SettingsDestination.pairing)
                    }
                    if let rulesUpdatedAt = model.settings.rulesUpdatedAt {
                        LabeledContent("Rules", value: "Checked \(rulesUpdatedAt.formatted(.relative(presentation: .named)))")
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
                    if model.pairing == .paired {
                        Button(SetupCopy.pairAgain) {
                            Task {
                                model.dismissFailure()
                                await model.beginReplacementPairing()
                                if model.failure == nil { path.append(.pairing) }
                            }
                        }
                    }
                } header: {
                    Text("This iPhone")
                } footer: {
                    Text(model.pairing == .paired ? SetupCopy.pairAgainFooter
                        : "Your approvals are signed with this key, which never leaves the iPhone's Secure Enclave.")
                }
            }
            .navigationDestination(for: SettingsDestination.self) { _ in PhonePairingView(model: model) }
            .alert("Something went wrong", isPresented: failureShown) {
                Button("OK") { model.dismissFailure() }
            } message: {
                Text(model.failure ?? "")
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

    private var failureShown: Binding<Bool> {
        Binding(get: { model.failure != nil }, set: { if !$0 { model.dismissFailure() } })
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
