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
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 48, height: 48)
                    .background(.teal.opacity(0.13), in: Circle())
                    .overlay {
                        Circle().stroke(.teal.opacity(0.20), lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 7) {
                    Text("LOCAL AGENT REQUEST")
                        .font(.callout.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(.teal)

                    Text("Approve credential access")
                        .font(.system(size: 27, weight: .semibold))
                        .tracking(-0.4)

                    Text(
                        "Check the destination and account, then approve once on Apple Watch or with Touch ID."
                    )
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                ApprovalDetailRow(
                    label: "Website",
                    value: request.destination,
                    symbol: "globe"
                )
                Divider().padding(.leading, 48)
                ApprovalDetailRow(
                    label: "Account",
                    value: request.account,
                    symbol: "person.crop.circle"
                )
                Divider().padding(.leading, 48)
                ApprovalDetailRow(
                    label: "Credential",
                    value: request.credentialTitle,
                    symbol: "rectangle.and.text.magnifyingglass"
                )
                Divider().padding(.leading, 48)
                ApprovalDetailRow(
                    label: "Access",
                    value: request.field.approvalDisplayName,
                    symbol: request.field.approvalSymbol
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
                    Text("Waiting for your approval")
                        .font(.headline)
                    Text(
                        "Approve once with Apple Watch or Touch ID. The clipboard clears after \(request.expirationSeconds) seconds."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

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
    let symbol: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.teal)
                .frame(width: 22)

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
