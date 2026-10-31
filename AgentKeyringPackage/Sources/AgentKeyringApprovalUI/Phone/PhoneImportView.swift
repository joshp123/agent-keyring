// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Passwords on this iPhone, opened from Settings. Optional: in release 4 the
// MacBook delivers logins and the iPhone only approves (RFC 0006), so nothing
// here gates approving. Apple only lets the Passwords app start an export, so
// the screen says exactly where to tap there.

#if os(iOS)
import SwiftUI

struct PhoneImportView: View {
    let model: PhoneKeyringModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(SetupCopy.phonePasswordsPurpose)
                    .font(.body)
                    .foregroundStyle(.secondary)
                Hairline()
                content
            }
            .padding(.horizontal, KeyringMetric.margin)
            .padding(.top, 8)
        }
        .navigationTitle(SetupCopy.phonePasswordsTitle)
        .navigationBarTitleDisplayMode(.inline)
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
            Label(reason, systemImage: "exclamationmark.circle.fill")
                .font(.body)
                .foregroundStyle(KeyringColour.denyText)
            steps
            allowExportsButton
        case let .imported(count, at):
            Text("\(count) logins on this iPhone, updated \(at.formatted(.relative(presentation: .named))). To add or change one, export again; logins you leave out are kept.")
                .font(.body)
            steps
            allowExportsButton
        default:
            steps
            allowExportsButton
        }
    }

    private var steps: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 14) {
            Step(number: 1, text: "Tap Allow Exports, so Passwords can export to Agent Keyring.")
            Step(number: 2, text: "In the Passwords app, tap ··· then Export Data to Another App.")
            Step(number: 3, text: "Choose Agent Keyring and confirm with Face ID.")
        }
    }

    // iOS lets an app ask to become an export destination, not open the export
    // screen in Passwords, so the button does only the first step.
    private var allowExportsButton: some View {
        Button("Allow Exports", action: model.importPasswords)
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
