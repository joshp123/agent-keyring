import SwiftUI

@available(macOS 26.0, *)
struct AccessPolicyDetailView: View {
    let policy: CredentialAccessPolicy
    let rows: [AccessCredentialRow]
    let searchText: String
    @Binding var selection: Set<UUID>
    @Binding var sortOrder: [KeyPathComparator<AccessCredentialRow>]
    let errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            AccessPolicyHeader(policy: policy, count: rows.count)
            Divider()
            AccessPolicyTable(
                rows: rows,
                searchText: searchText,
                selection: $selection,
                sortOrder: $sortOrder
            )

            if let errorMessage {
                AccessControlErrorRow(message: errorMessage)
            }
        }
    }
}

@available(macOS 26.0, *)
private struct AccessPolicyHeader: View {
    let policy: CredentialAccessPolicy
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: policy.symbol)
                .font(.title2)
                .foregroundStyle(policy.colour)
                .frame(width: 44, height: 44)
                .background(policy.colour.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(policy.displayName)
                    .font(.title2.weight(.semibold))
                Text(policy.detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(count) credentials")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(policy.colour)
            }
            Spacer()
        }
        .padding(24)
    }
}

@available(macOS 26.0, *)
private struct AccessPolicyTable: View {
    let rows: [AccessCredentialRow]
    let searchText: String
    @Binding var selection: Set<UUID>
    @Binding var sortOrder: [KeyPathComparator<AccessCredentialRow>]

    var body: some View {
        if rows.isEmpty {
            if searchText.isEmpty {
                ContentUnavailableView(
                    "No credentials in this group",
                    systemImage: "tray",
                    description: Text("Select credentials in another group and use Move to.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Credential", value: \.title) { row in
                    CredentialNameCell(title: row.title, account: row.account)
                }
                .width(min: 250, ideal: 340)

                TableColumn("Website", value: \.website) { row in
                    Text(row.website)
                        .lineLimit(1)
                        .help(row.website)
                }
                .width(min: 180, ideal: 260)
            }
        }
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
struct MovePolicyMenu: View {
    let currentPolicy: CredentialAccessPolicy?
    let selectionCount: Int
    let move: (CredentialAccessPolicy) -> Void

    var body: some View {
        Menu {
            ForEach(CredentialAccessPolicy.allCases, id: \.self) { policy in
                if policy != currentPolicy {
                    Button {
                        move(policy)
                    } label: {
                        Label(policy.displayName, systemImage: policy.symbol)
                    }
                }
            }
        } label: {
            Label(
                selectionCount == 1 ? "Move credential" : "Move \(selectionCount) credentials",
                systemImage: "arrow.right"
            )
        }
        .disabled(selectionCount == 0)
        .help("Move the selected credentials to another access group")
    }
}

@available(macOS 26.0, *)
struct AccessControlErrorRow: View {
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
