// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Which logins agents may use. A rule is a property of a login, so it is a
// column you change in place, not a folder you move logins between. The
// sidebar filters by rule and keeps the three counts in view.

#if os(macOS)
import SwiftUI

public struct MacRulesView: View {
    @Bindable var model: MacRulesModel

    public init(model: MacRulesModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: filterSelection) {
                Section {
                    FilterRow(title: "All logins", symbol: "key.horizontal", colour: .secondary,
                        count: model.count(.all))
                        .tag(LoginRuleFilter.all)
                }
                Section("Rules") {
                    ForEach(LoginRule.allCases, id: \.self) { rule in
                        FilterRow(title: rule.name, symbol: rule.symbol, colour: rule.colour,
                            count: model.count(.rule(rule)))
                            .tag(LoginRuleFilter.rule(rule))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    model.openAssistant()
                } label: {
                    Label("Set rules with AI…", systemImage: "sparkles")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            RulesTable(model: model)
        }
        .searchable(text: $model.searchText, prompt: "Search logins")
        .alert("Rules weren't saved", isPresented: failureShown) {
            Button("OK") { model.dismissFailure() }
        } message: {
            Text(model.failure ?? "")
        }
    }

    private var filterSelection: Binding<LoginRuleFilter?> {
        Binding(get: { model.filter }, set: { if let filter = $0 { model.filter = filter } })
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { model.failure != nil }, set: { if !$0 { model.dismissFailure() } })
    }
}

private struct FilterRow: View {
    let title: String
    let symbol: String
    let colour: Color
    let count: Int

    var body: some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(colour)
            }
            Spacer()
            Text(count, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

private struct RulesTable: View {
    @Bindable var model: MacRulesModel

    var body: some View {
        VStack(spacing: 0) {
            RulesHeader(filter: model.filter, shown: model.visibleRows.count)
            Divider()
            Table(model.visibleRows, selection: $model.selection, sortOrder: $model.sortOrder) {
                TableColumn("Login", value: \.site) { row in
                    Text(row.site).fontWeight(.medium)
                }
                .width(min: 180, ideal: 240)

                TableColumn("Account", value: \.account) { row in
                    Text(row.account).foregroundStyle(.secondary)
                }
                .width(min: 140, ideal: 200)

                TableColumn("Rule") { row in
                    RulePicker(rule: row.rule) { rule in
                        Task { await model.setRule(rule, for: [row.id]) }
                    }
                }
                .width(min: 120, ideal: 130, max: 160)

                TableColumn("Last used") { row in
                    Text(row.lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(min: 90, ideal: 110)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                SetRuleMenuItems(count: ids.count) { rule in
                    Task { await model.setRule(rule, for: ids) }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    SetRuleMenuItems(count: model.selection.count) { rule in
                        Task { await model.setRule(rule, for: model.selection) }
                    }
                } label: {
                    Label("Set Rule", systemImage: "slider.horizontal.3")
                }
                .disabled(model.selection.isEmpty)
                .help("Set the rule for the selected logins")
            }
        }
    }
}

/// The rule for one login, changed where it is shown.
private struct RulePicker: View {
    let rule: LoginRule
    let change: (LoginRule) -> Void

    var body: some View {
        // Menus draw their label as a template, so the coloured symbol sits outside it.
        HStack(spacing: 6) {
            Image(systemName: rule.symbol).foregroundStyle(rule.colour)
            Menu(rule.name) {
                ForEach(LoginRule.allCases, id: \.self) { option in
                    Button {
                        change(option)
                    } label: {
                        Label(option.name, systemImage: option == rule ? "checkmark" : option.symbol)
                    }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
        }
    }
}

private struct SetRuleMenuItems: View {
    let count: Int
    let change: (LoginRule) -> Void

    var body: some View {
        Section(count == 1 ? "Set rule" : "Set rule for \(count) logins") {
            ForEach(LoginRule.allCases, id: \.self) { rule in
                Button(rule.name, systemImage: rule.symbol) { change(rule) }
            }
        }
    }
}

private struct RulesHeader: View {
    let filter: LoginRuleFilter
    let shown: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.bold))
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var title: String {
        switch filter {
        case .all: "All logins"
        case let .rule(rule): rule.name
        }
    }

    private var explanation: String {
        switch filter {
        case .all: "Every login from Apple Passwords. Change a rule in the Rule column."
        case let .rule(rule): rule.explanation
        }
    }
}
#endif
