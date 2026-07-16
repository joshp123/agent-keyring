import SwiftUI

@available(macOS 26.0, *)
struct AccessPolicySidebar: View {
    @Binding var selectedPolicy: CredentialAccessPolicy?
    let askCount: Int
    let automaticCount: Int
    let blockedCount: Int
    let openAssistant: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Agent access rules")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 20)

            Text("HOW AGENTS USE CREDENTIALS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            VStack(spacing: 4) {
                ForEach(CredentialAccessPolicy.allCases, id: \.self) { policy in
                    Button {
                        selectedPolicy = policy
                    } label: {
                        AccessPolicySidebarRow(
                            policy: policy,
                            count: count(for: policy)
                        )
                    }
                    .buttonStyle(.plain)
                    .background(
                        selectedPolicy == policy ? Color.accentColor.opacity(0.14) : .clear,
                        in: .rect(cornerRadius: 7)
                    )
                    .accessibilityIdentifier("policy-\(policy.rawValue)")
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 12)
            Divider()
            AssistantSidebarAction(action: openAssistant)
        }
        .background(.regularMaterial)
    }

    private func count(for policy: CredentialAccessPolicy) -> Int {
        switch policy {
        case .ask: askCount
        case .allowAutomatically: automaticCount
        case .block: blockedCount
        }
    }
}

@available(macOS 26.0, *)
private struct AccessPolicySidebarRow: View {
    let policy: CredentialAccessPolicy
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: policy.symbol)
                .foregroundStyle(policy.colour)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(policy.displayName)
                    .lineLimit(1)
                Text(policy.sidebarDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(count, format: .number)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .contentShape(.rect)
    }
}

@available(macOS 26.0, *)
private struct AssistantSidebarAction: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI suggestions…")
                    Text("Review every change before applying")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(8)
        .help("Ask your AI to suggest rules, then review every change")
        .accessibilityIdentifier("policy-assistant")
    }
}
