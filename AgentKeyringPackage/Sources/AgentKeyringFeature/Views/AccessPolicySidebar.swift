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
            .padding(.top, 8)

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
                if let detail = policy.sidebarDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
                    Text("Set Rules with AI…")
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(8)
        .help("Use an AI to propose access rules, then review every change")
        .accessibilityIdentifier("policy-assistant")
    }
}
