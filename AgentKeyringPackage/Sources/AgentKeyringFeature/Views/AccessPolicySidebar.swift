import SwiftUI

@available(macOS 26.0, *)
struct AccessPolicySidebar: View {
    @Binding var selectedPolicy: CredentialAccessPolicy?
    let askCount: Int
    let automaticCount: Int
    let blockedCount: Int
    let openAssistant: () -> Void

    var body: some View {
        List(selection: $selectedPolicy) {
            Section("Access groups") {
                ForEach(CredentialAccessPolicy.allCases, id: \.self) { policy in
                    AccessPolicySidebarRow(
                        policy: policy,
                        count: count(for: policy)
                    )
                    .tag(policy)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            AssistantSidebarAction(action: openAssistant)
        }
        .navigationTitle("Credential access")
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
    }
}

@available(macOS 26.0, *)
private struct AssistantSidebarAction: View {
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Button(action: action) {
                Label("Let your AI choose…", systemImage: "sparkles")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .help("Create a prompt and import the model's recommendations")
        }
        .padding(12)
        .background(.regularMaterial)
    }
}
