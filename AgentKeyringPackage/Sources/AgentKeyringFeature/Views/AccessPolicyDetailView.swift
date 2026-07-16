import SwiftUI

@available(macOS 26.0, *)
struct AccessPolicyDetailView: View {
    let policy: CredentialAccessPolicy
    let rows: [AccessCredentialRow]
    @Binding var searchText: String
    @Binding var selection: Set<UUID>
    let errorMessage: String?
    let changePolicy: (CredentialAccessPolicy) -> Void

    var body: some View {
        VStack(spacing: 0) {
            AccessPolicyList(
                rows: rows,
                searchText: $searchText,
                selection: $selection
            )

            if !selection.isEmpty {
                AccessRuleSelectionBar(
                    currentPolicy: policy,
                    selectionCount: selection.count,
                    changePolicy: changePolicy
                )
            }

            if let errorMessage {
                AccessControlErrorRow(message: errorMessage)
            }
        }
        .accessibilityIdentifier("policy-detail-\(policy.rawValue)")
    }
}

@available(macOS 26.0, *)
private struct AccessPolicyList: View {
    let rows: [AccessCredentialRow]
    @Binding var searchText: String
    @Binding var selection: Set<UUID>

    var body: some View {
        VStack(spacing: 0) {
            AccessPolicySearchField(searchText: $searchText)
            AccessCredentialColumnHeadings(
                allRowsSelected: allRowsSelected,
                someRowsSelected: someRowsSelected,
                toggleAll: toggleAll
            )
            Divider()

            if rows.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView(
                        "No logins under this rule",
                        systemImage: "tray",
                        description: Text("Choose another rule to find logins.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            AccessCredentialListRow(
                                row: row,
                                isSelected: selection.contains(row.id),
                                toggleSelection: { toggleSelection(row.id) }
                            )
                            Divider().padding(.leading, 50)
                        }
                    }
                }
                .accessibilityIdentifier("credential-list")
            }
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private var selectedRowCount: Int {
        rows.lazy.filter { selection.contains($0.id) }.count
    }

    private var allRowsSelected: Bool {
        !rows.isEmpty && selectedRowCount == rows.count
    }

    private var someRowsSelected: Bool {
        selectedRowCount > 0 && !allRowsSelected
    }

    private func toggleAll() {
        let visibleIDs = Set(rows.map(\.id))
        if allRowsSelected {
            selection.subtract(visibleIDs)
        } else {
            selection.formUnion(visibleIDs)
        }
    }
}

@available(macOS 26.0, *)
private struct AccessPolicySearchField: View {
    @Binding var searchText: String

    var body: some View {
        TextField("Search logins", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 360)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("credential-search")
    }
}

@available(macOS 26.0, *)
private struct AccessCredentialColumnHeadings: View {
    let allRowsSelected: Bool
    let someRowsSelected: Bool
    let toggleAll: () -> Void

    var body: some View {
        AccessCredentialColumns(
            selection: {
                Button(action: toggleAll) {
                    Image(systemName: selectionSymbol)
                }
                .buttonStyle(.plain)
                .help(
                    allRowsSelected
                        ? "Deselect all shown logins" : "Select all shown logins"
                )
                .accessibilityLabel(
                    allRowsSelected
                        ? "Deselect all shown logins" : "Select all shown logins"
                )
                .accessibilityIdentifier("select-all-credentials")
            },
            credential: { Text("Login") },
            account: { Text("Account") },
            website: { Text("Website") }
        )
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.35))
    }

    private var selectionSymbol: String {
        if allRowsSelected { return "checkmark.square.fill" }
        if someRowsSelected { return "minus.square.fill" }
        return "square"
    }
}

@available(macOS 26.0, *)
private struct AccessCredentialListRow: View {
    let row: AccessCredentialRow
    let isSelected: Bool
    let toggleSelection: () -> Void

    var body: some View {
        Button(action: toggleSelection) {
            AccessCredentialColumns(
                selection: {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                },
                credential: {
                    Text(row.title)
                        .font(.body.weight(.medium))
                        .help(row.title)
                },
                account: { Text(row.account).help(row.account) },
                website: {
                    Text(row.website == row.title ? "—" : row.website)
                        .help(row.website)
                }
            )
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(.rect)
            .background(isSelected ? Color.accentColor.opacity(0.1) : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("credential-\(row.id.uuidString)")
    }
}

@available(macOS 26.0, *)
private struct AccessCredentialColumns<
    Selection: View, Credential: View, Account: View, Website: View
>: View {
    @ViewBuilder let selection: Selection
    @ViewBuilder let credential: Credential
    @ViewBuilder let account: Account
    @ViewBuilder let website: Website

    var body: some View {
        HStack(spacing: 12) {
            selection.frame(width: 26)
            credential.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            account.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            website.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
        }
    }
}

@available(macOS 26.0, *)
private struct AccessRuleSelectionBar: View {
    let currentPolicy: CredentialAccessPolicy
    let selectionCount: Int
    let changePolicy: (CredentialAccessPolicy) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(selectionCount) selected")
                .font(.callout.weight(.medium))
            Spacer()
            ChangeAccessRuleMenu(
                currentPolicy: currentPolicy,
                selectionCount: selectionCount,
                changePolicy: changePolicy
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

@available(macOS 26.0, *)
struct ChangeAccessRuleMenu: View {
    let currentPolicy: CredentialAccessPolicy
    let selectionCount: Int
    let changePolicy: (CredentialAccessPolicy) -> Void

    var body: some View {
        Menu {
            Section("Set access rule") {
                ForEach(CredentialAccessPolicy.allCases, id: \.self) { policy in
                    Button {
                        changePolicy(policy)
                    } label: {
                        Label(
                            policy.displayName,
                            systemImage: policy == currentPolicy ? "checkmark" : policy.symbol
                        )
                    }
                    .disabled(policy == currentPolicy)
                }
            }
        } label: {
            Label(
                selectionCount == 1 ? "Change access rule…" : "Change access rules…",
                systemImage: "slider.horizontal.3"
            )
        }
        .help("Set the access rule for the selected logins")
        .accessibilityIdentifier("change-access-rule")
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
