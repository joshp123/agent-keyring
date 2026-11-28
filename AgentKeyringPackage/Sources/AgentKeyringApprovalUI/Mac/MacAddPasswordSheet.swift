// Written by AI on 2026.11.25 by model gemini-4-neon; split into its own file on 2026.11.27 by model claude opus 5.5.
//
// The manual Add a Password sheet (Cmd-N / Add Manually).

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

public struct MacAddPasswordSheet: View {
    public static let width: CGFloat = 484

    @State private var website: String = ""
    @State private var account: String = ""
    @State private var password: String = ""
    @State private var totpSecret: String = ""
    @State private var rule: LoginRule = .ask
    @State private var isSaving = false
    @State private var errorMessage: String?

    let onSave: (String, String, String, String?, LoginRule) async throws -> Void
    let onCancel: () -> Void

    public init(
        onSave: @escaping (String, String, String, String?, LoginRule) async throws -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var canSubmit: Bool {
        !website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && !isSaving
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s4) {
            VStack(alignment: .leading, spacing: KeyringSpace.s1) {
                KeyringText(ManualAddCopy.title, as: .title)
                KeyringText(ManualAddCopy.subtitle, as: .meta)
            }

            VStack(spacing: 0) {
                formRow(label: ManualAddCopy.websiteLabel) {
                    HStack(spacing: 7) {
                        if !website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            SiteIconView(host: website, size: 18)
                        }
                        TextField(ManualAddCopy.websitePlaceholder, text: $website)
                            .textFieldStyle(.plain)
                    }
                }
                Divider()
                formRow(label: ManualAddCopy.accountLabel) {
                    TextField(ManualAddCopy.accountPlaceholder, text: $account)
                        .textFieldStyle(.plain)
                }
                Divider()
                formRow(label: ManualAddCopy.passwordLabel) {
                    SecureField(ManualAddCopy.passwordPlaceholder, text: $password)
                        .textFieldStyle(.plain)
                }
                Divider()
                formRow(label: ManualAddCopy.totpLabel) {
                    VStack(alignment: .leading, spacing: 3) {
                        SecureField(ManualAddCopy.totpPlaceholder, text: $totpSecret)
                            .textFieldStyle(.plain)
                        KeyringText(ManualAddCopy.totpHint, as: .caption, colour: KeyringPalette.ink3)
                    }
                }
                Divider()
                formRow(label: ManualAddCopy.ruleLabel) {
                    Picker(ManualAddCopy.ruleLabel, selection: $rule) {
                        Text(LoginRule.ask.name).tag(LoginRule.ask)
                        Text(LoginRule.automatic.name).tag(LoginRule.automatic)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 230, alignment: .leading)
                }
            }
            .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card))
            .clipShape(.rect(cornerRadius: KeyringRadius.card))
            .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card).strokeBorder(KeyringPalette.line))

            KeyringText(ManualAddCopy.ruleNote, as: .caption)

            if let errorMessage {
                KeyringStatusLine(.problem(errorMessage))
            }

            Divider()

            HStack(spacing: KeyringSpace.s2) {
                Spacer(minLength: 0)
                KeyringButton(.plain(ManualAddCopy.cancel, isEnabled: !isSaving, perform: onCancel))
                KeyringButton(.advance(
                    isSaving ? ManualAddCopy.adding : ManualAddCopy.addPassword,
                    isEnabled: canSubmit,
                    perform: submit
                ))
            }
        }
        .padding(KeyringSpace.s5)
        .frame(width: Self.width)
        .background(KeyringPalette.surface)
    }

    private func formRow<Field: View>(label: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(alignment: .center, spacing: KeyringSpace.s3) {
            KeyringText(label, as: .caption)
                .frame(width: 104, alignment: .trailing)
            field()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, KeyringSpace.s3)
        .padding(.vertical, 10)
    }

    private func submit() {
        errorMessage = nil
        isSaving = true
        let site = website
        let acct = account
        let pass = password
        let totp = totpSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : totpSecret
        let chosenRule = rule
        Task {
            do {
                try await onSave(site, acct, pass, totp, chosenRule)
                await MainActor.run {
                    isSaving = false
                    onCancel()
                }
            } catch is CancellationError {
                await MainActor.run {
                    isSaving = false
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}
#endif
