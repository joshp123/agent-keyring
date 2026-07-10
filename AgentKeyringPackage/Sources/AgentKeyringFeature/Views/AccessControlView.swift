import SwiftUI

@available(macOS 26.0, *)
public struct AccessControlView: View {
    @State private var selection = Set<UUID>()
    private let controller: CredentialAccessController

    public init(controller: CredentialAccessController) {
        self.controller = controller
    }

    public var body: some View {
        @Bindable var controller = controller

        VStack(spacing: 0) {
            AccessControlHeader(
                totalCount: controller.rows.count,
                askCount: controller.count(for: .ask),
                automaticCount: controller.count(for: .allowAutomatically),
                blockedCount: controller.count(for: .block)
            )

            Divider()

            if controller.rows.isEmpty {
                ContentUnavailableView(
                    "No mirrored credentials",
                    systemImage: "key.horizontal",
                    description: Text("Refresh from Apple Passwords before setting access rules.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if controller.visibleRows.isEmpty {
                ContentUnavailableView.search(text: controller.searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(
                    controller.visibleRows,
                    selection: $selection,
                    sortOrder: $controller.sortOrder
                ) {
                    TableColumn("Credential", value: \.title) { row in
                        CredentialNameCell(title: row.title, account: row.account)
                    }
                    .width(min: 210, ideal: 280)

                    TableColumn("Website", value: \.website) { row in
                        Text(row.website)
                            .lineLimit(1)
                            .help(row.website)
                    }
                    .width(min: 150, ideal: 220)

                    TableColumn("Access", value: \.policy.sortKey) { row in
                        AccessPolicyMenu(policy: row.policy) { policy in
                            Task { await controller.setPolicy(policy, for: [row.id]) }
                        }
                    }
                    .width(min: 170, ideal: 190)
                }
            }

            if let errorMessage = controller.errorMessage {
                AccessControlErrorRow(message: errorMessage)
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .searchable(
            text: $controller.searchText,
            placement: .toolbar,
            prompt: "Search credentials"
        )
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Show", selection: $controller.filter) {
                    ForEach(CredentialAccessFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.menu)

                BulkPolicyMenu(selection: selection) { policy in
                    Task {
                        await controller.setPolicy(policy, for: selection)
                        selection.removeAll()
                    }
                }
            }
        }
    }
}

@available(macOS 26.0, *)
private struct AccessControlHeader: View {
    let totalCount: Int
    let askCount: Int
    let automaticCount: Int
    let blockedCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "person.badge.key.fill")
                .font(.title2)
                .foregroundStyle(.teal)
                .frame(width: 44, height: 44)
                .background(.teal.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text("Credential access")
                    .font(.title2.weight(.semibold))
                Text(
                    "Choose which local agent requests need approval. New credentials ask every time."
                )
                .font(.body)
                .foregroundStyle(.secondary)
                Text(
                    "\(totalCount) credentials · \(askCount) ask · \(automaticCount) automatic · \(blockedCount) blocked"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
    }
}

@available(macOS 26.0, *)
private struct CredentialNameCell: View {
    let title: String
    let account: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(1)
            Text(account)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help("\(title)\n\(account)")
    }
}

@available(macOS 26.0, *)
private struct AccessPolicyMenu: View {
    let policy: CredentialAccessPolicy
    let changePolicy: (CredentialAccessPolicy) -> Void

    var body: some View {
        Menu {
            ForEach(CredentialAccessPolicy.allCases, id: \.self) { option in
                Button {
                    changePolicy(option)
                } label: {
                    if option == policy {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Label(policy.title, systemImage: policy.symbol)
                .foregroundStyle(policy.colour)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@available(macOS 26.0, *)
private struct BulkPolicyMenu: View {
    let selection: Set<UUID>
    let changePolicy: (CredentialAccessPolicy) -> Void

    var body: some View {
        Menu {
            ForEach(CredentialAccessPolicy.allCases, id: \.self) { policy in
                Button {
                    changePolicy(policy)
                } label: {
                    Label(policy.title, systemImage: policy.symbol)
                }
            }
        } label: {
            Label(
                selection.isEmpty ? "Set access" : "Set access for \(selection.count)",
                systemImage: "checklist"
            )
        }
        .disabled(selection.isEmpty)
        .help("Change access for the selected credentials")
    }
}

@available(macOS 26.0, *)
private struct AccessControlErrorRow: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.orange.opacity(0.08))
    }
}

@available(macOS 26.0, *)
private extension CredentialAccessPolicy {
    var symbol: String {
        switch self {
        case .ask: "applewatch"
        case .allowAutomatically: "checkmark.circle.fill"
        case .block: "nosign"
        }
    }

    var colour: Color {
        switch self {
        case .ask: .teal
        case .allowAutomatically: .green
        case .block: .red
        }
    }
}
