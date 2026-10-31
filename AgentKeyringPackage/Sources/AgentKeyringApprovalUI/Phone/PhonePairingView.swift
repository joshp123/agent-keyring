// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Pairing this iPhone with the relay (RFC 0006). Josh enters the relay's
// address; the phone shows a code to compare with the Mac's, in the same
// two rows of four groups; he approves on the Mac with Touch ID and the
// phone finishes by itself. There is no confirm button here: the Mac's
// signed approval is the confirmation, and the phone checks it.

#if os(iOS)
import SwiftUI

struct PhonePairingView: View {
    let model: PhoneKeyringModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch model.pairing {
                case .notPaired:
                    addressForm(failure: nil)
                case let .failed(message):
                    addressForm(failure: message)
                case .connecting:
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(SetupCopy.pairingConnecting)
                    }
                    .font(.body)
                    cancelButton
                case let .comparing(fingerprint, relayAddress):
                    comparing(fingerprint: fingerprint, relayAddress: relayAddress)
                case .paired:
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(KeyringColour.approveText)
                        Text(SetupCopy.pairingPaired)
                            .font(.body.weight(.semibold))
                    }
                    Button("Done") { dismiss() }
                        .buttonStyle(.quiet())
                }
            }
            .padding(.horizontal, KeyringMetric.margin)
            .padding(.top, 8)
        }
        .navigationTitle(SetupCopy.pairTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: model.pairing == .paired)
    }

    @ViewBuilder private func addressForm(failure: String?) -> some View {
        Text(SetupCopy.pairIntro)
            .font(.body)
            .foregroundStyle(.secondary)
        if let failure {
            Label(failure, systemImage: "exclamationmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(KeyringColour.denyText)
        }
        VStack(alignment: .leading, spacing: 6) {
            Text(SetupCopy.relayAddress)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("mac-mini:17443", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($addressFocused)
                .font(.body.monospaced())
                .padding(12)
                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 12, style: .continuous))
                .onSubmit(pair)
        }
        Button(failure == nil ? SetupCopy.pairButton : SetupCopy.tryAgain, action: pair)
            .buttonStyle(DecisionButtonStyle(colour: KeyringColour.signal))
            .disabled(endpoint == nil)
    }

    @ViewBuilder private func comparing(fingerprint: String, relayAddress: String) -> some View {
        Text(SetupCopy.pairingCompareHere)
            .font(.headline)
        FingerprintGrid(fingerprint, size: .title3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        Text(SetupCopy.allGroupsMustMatch)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        Hairline()
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ProgressView()
            Text(SetupCopy.pairingConfirmOnMac)
                .font(.body)
        }
        Text("Relay: \(relayAddress)")
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
        Button(SetupCopy.doesNotMatch) { model.cancelPairing() }
            .buttonStyle(.quiet(text: KeyringColour.denyText))
    }

    private var cancelButton: some View {
        Button("Cancel") { model.cancelPairing() }
            .buttonStyle(.quiet())
    }

    /// "mac-mini:17443" into host and port.
    private var endpoint: PhoneRelayEndpoint? {
        let parts = address.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, !parts[0].isEmpty, let port = UInt16(parts[1]) else { return nil }
        return PhoneRelayEndpoint(host: String(parts[0]), port: port)
    }

    private func pair() {
        guard let endpoint else { return }
        addressFocused = false
        Task { await model.beginPairing(endpoint: endpoint) }
    }
}
#endif
