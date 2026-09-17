import SwiftUI

@available(macOS 26.0, *)
struct CredentialReleaseApprovalView: View {
    let request: CredentialReleaseAuthorizationRequest
    let showsProgressIndicator: Bool

    init(
        request: CredentialReleaseAuthorizationRequest,
        showsProgressIndicator: Bool = true
    ) {
        self.request = request
        self.showsProgressIndicator = showsProgressIndicator
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 48, height: 48)
                    .background(.teal.opacity(0.13), in: Circle())
                    .overlay {
                        Circle().stroke(.teal.opacity(0.20), lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Approve \(request.field.approvalDisplayName.lowercased())")
                        .font(.system(size: 27, weight: .semibold))
                        .tracking(-0.4)

                    Text(request.destination)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            VStack(spacing: 0) {
                ApprovalDetailRow(
                    label: "Account",
                    value: request.account
                )
                Divider().padding(.leading, 16)
                ApprovalDetailRow(
                    label: "Login",
                    value: request.credentialTitle
                )
            }
            .background(.primary.opacity(0.045), in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
            }

            HStack(spacing: 14) {
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(.teal)

                VStack(alignment: .leading, spacing: 3) {
                    if let expirationSeconds = request.expirationSeconds {
                        Text("Approve with Apple Watch or Touch ID. Clipboard clears \(expirationSeconds) seconds after approval.")
                    } else {
                        Text("Approve with Apple Watch or Touch ID. The agent retains this value until it explicitly clears it.")
                    }
                }
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

                Spacer()
                if showsProgressIndicator {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .background(.teal.opacity(0.08), in: .rect(cornerRadius: 16))
        }
        .padding(24)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("credential-release-approval")
    }
}

@available(macOS 26.0, *)
private struct ApprovalDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 14) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)

            Text(value)
                .font(.body.weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
