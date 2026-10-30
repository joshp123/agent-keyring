// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Before the first import there is nothing to approve, so this replaces the
// home screen. Apple only lets the Passwords app start an export, so the
// screen says exactly where to tap.

#if os(iOS)
import SwiftUI

struct PhoneImportView: View {
    let model: PhoneKeyringModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Agent Keyring keeps an encrypted copy of your Apple Passwords on this iPhone. Agents never see it: Agent Keyring fills the sign-in for them, after you approve.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Hairline()
                content
            }
            .padding(.horizontal, KeyringMetric.margin)
            .padding(.top, 8)
        }
        .navigationTitle(title)
    }

    private var title: String {
        switch model.passwords {
        case .importing: "Importing passwords"
        case .importFailed: "The import didn't finish"
        default: "Import passwords"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.passwords {
        case let .importing(received):
            HStack(spacing: 12) {
                ProgressView()
                Text("\(received) logins so far. Keep Passwords open until it finishes.")
                    .font(.body)
            }
        case let .importFailed(reason):
            Text(reason).font(.body)
            steps
            openPasswordsButton(title: "Try again in Passwords")
        default:
            steps
            openPasswordsButton(title: "Open Passwords")
        }
    }

    private var steps: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 14) {
            Step(number: 1, text: "Open the Passwords app.")
            Step(number: 2, text: "Tap ··· then Export Data to Another App.")
            Step(number: 3, text: "Choose Agent Keyring and confirm with Face ID.")
        }
    }

    private func openPasswordsButton(title: String) -> some View {
        Button(title, action: model.importPasswords)
            .buttonStyle(DecisionButtonStyle(colour: KeyringColour.signal))
            .padding(.top, 6)
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        GridRow {
            Text("\(number)")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(KeyringColour.signal)
            Text(text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
