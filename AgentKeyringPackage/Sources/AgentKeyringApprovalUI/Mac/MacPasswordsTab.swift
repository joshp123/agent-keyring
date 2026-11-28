// Written by AI on 2026.11.21 by model claude opus 5.5; rebuilt on 2026.11.26
// by model gemini-4-neon with full-width scrolling 548+ Table (no Inspector, no
// Review Rules with Agent, no staging bar), composable Rule x Category filters
// (Option A semantic rule colours, Option B plain-text categories), and
// discoverable checkbox multi-select Edit Mode with one Touch ID confirmation.

#if os(macOS)
import AppKit
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

public struct MacPasswordsTab: View {
    @Bindable var model: MacMainModel

    public init(model: MacMainModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            filterHeader
            if model.isEditingRules {
                editActionBar
            }
            Divider()
            if model.visibleLogins.isEmpty {
                emptyState
            } else {
                table
                    .background(KeyringPalette.surface)
            }
            Divider()
            footer
        }
        .background(KeyringPalette.canvas)
        .searchable(text: $model.search, placement: .toolbar, prompt: Text(MainWindowCopy.search(model.snapshot.logins.count)))
    }

    // MARK: Composable Filter Bar (Option A Rule colours + Option B Plain-text Categories, matched 28pt circular capsules)

    private var filterHeader: some View {
        HStack(spacing: KeyringSpace.s2) {
            KeyringFilterPill(
                title: MainWindowCopy.all,
                count: model.loginCount(nil),
                symbol: "key.fill",
                tint: KeyringPalette.brand,
                active: model.ruleFilter == nil
            ) {
                model.ruleFilter = nil
            }

            ForEach(LoginRule.allCases, id: \.self) { rule in
                KeyringFilterPill(
                    title: rule.name,
                    count: model.loginCount(rule),
                    symbol: rule.visual.symbol,
                    tint: rule.visual.tint,
                    active: model.ruleFilter == rule
                ) {
                    model.ruleFilter = (model.ruleFilter == rule) ? nil : rule
                }
            }

            Spacer(minLength: KeyringSpace.s2)

            // Option B: Plain text + tabular count (no category icons), exact same 28pt height and circular capsule stroke.
            Menu {
                Button {
                    model.categoryFilter = nil
                } label: {
                    HStack {
                        Text("All Categories (\(model.allCategories.count))")
                        if model.categoryFilter == nil { Image(systemName: "checkmark") }
                    }
                }
                Divider()
                ForEach(model.allCategories, id: \.id) { cat in
                    Button {
                        model.categoryFilter = cat.id
                    } label: {
                        HStack {
                            Text("\(cat.title) (\(cat.count.formatted()))")
                            if model.categoryFilter == cat.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(model.categoryFilter.map { MacImportCategoryOption.title(for: $0) } ?? "All Categories (\(model.allCategories.count))")
                        .font(KeyringFont.fixed(KeyringFont.PostScript.regular, size: 12))
                        .foregroundStyle(model.categoryFilter != nil ? KeyringPalette.brand : KeyringPalette.ink)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(model.categoryFilter != nil ? KeyringPalette.brand : KeyringPalette.ink2)
                        .accessibilityHidden(true)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(model.categoryFilter != nil ? KeyringPalette.brandTint : KeyringPalette.surface, in: Capsule(style: .circular))
            .overlay(
                Capsule(style: .circular)
                    .strokeBorder(model.categoryFilter != nil ? KeyringPalette.brand.opacity(0.45) : KeyringPalette.line, lineWidth: 1)
            )
        }
        .padding(.horizontal, KeyringSpace.s5)
        .padding(.vertical, KeyringSpace.s3)
    }

    // MARK: Discoverable Multi-Select Edit Bar (columns never jump; picking a rule opens one Touch ID confirmation sheet)

    private var editActionBar: some View {
        let count = model.selectedForEdit.count
        return HStack(spacing: KeyringSpace.s3) {
            KeyringText(
                count == 0 ? "Select passwords to change their rule" : "\(count.formatted()) selected",
                as: .heading,
                colour: count == 0 ? KeyringPalette.ink2 : KeyringPalette.ink
            )
            .monospacedDigit()

            Spacer(minLength: KeyringSpace.s2)

            HStack(spacing: KeyringSpace.s2) {
                KeyringText("Set Rule:", as: .meta)
                ForEach(LoginRule.allCases, id: \.self) { rule in
                    Button {
                        model.requestRuleChange(rule)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: rule.visual.symbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(count == 0 ? KeyringPalette.ink3 : rule.visual.tint)
                            KeyringText(rule.name, as: .meta, colour: count == 0 ? KeyringPalette.ink3 : rule.visual.tint)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(count == 0 ? KeyringPalette.fill : rule.visual.tintBackground, in: Capsule(style: .circular))
                    }
                    .buttonStyle(.plain)
                    .disabled(count == 0 || model.isWorking)
                }
            }

            if count > 0 {
                KeyringButton(.plain("Clear") { model.clearEditSelection() })
            }
        }
        .padding(.horizontal, KeyringSpace.s5)
        .padding(.vertical, KeyringSpace.s2 + 2)
        .background(KeyringPalette.brandTint.opacity(0.6))
    }

    // MARK: Full-Width Real Scrolling Table (7 atomic columns; leading checkbox inside Website column during Edit Mode so columns never shift)

    private var table: some View {
        Table(model.visibleLogins, sortOrder: $model.sortOrder) {
            TableColumn(MainWindowCopy.website, value: \.site) { row in
                HStack(alignment: .center, spacing: KeyringSpace.s2) {
                    if model.isEditingRules {
                        let checked = model.selectedForEdit.contains(row.id)
                        Button {
                            model.toggleEditSelection(row.id)
                        } label: {
                            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(checked ? KeyringPalette.brand : KeyringPalette.ink3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(checked ? "Deselect \(row.site)" : "Select \(row.site)")
                    }
                    SiteIconView(host: row.site, size: 18)
                    KeyringText(row.site, as: .heading, fit: .siteName)
                        .lineLimit(2)
                }
                .padding(.vertical, 3)
            }
            .width(min: 118, ideal: 165)

            TableColumn("Account", value: \.account) { row in
                KeyringText(
                    row.account.isEmpty ? "No username" : row.account,
                    as: .meta,
                    colour: row.account.isEmpty ? KeyringPalette.ink3 : KeyringPalette.ink2
                )
                .lineLimit(1)
            }
            .width(min: 105, ideal: 145)

            // Option B settled choice: Plain text categories (no category icons).
            TableColumn("Category") { row in
                KeyringText(MacImportCategoryOption.title(for: row.category), as: .meta)
                    .lineLimit(1)
            }
            .width(min: 86, ideal: 100)

            TableColumn(MainWindowCopy.asked, value: \.asked) { row in
                KeyringText(row.asked.formatted(), as: .body, colour: row.asked == 0 ? KeyringPalette.ink3 : KeyringPalette.ink)
                    .monospacedDigit()
            }
            .width(62).alignment(.trailing)

            TableColumn(MainWindowCopy.approved, value: \.approved) { row in
                KeyringText(row.approved.formatted(), as: .body, colour: row.approved == 0 ? KeyringPalette.ink3 : KeyringPalette.ink)
                    .monospacedDigit()
            }
            .width(68).alignment(.trailing)

            TableColumn(MainWindowCopy.denied, value: \.denied) { row in
                KeyringText(row.denied.formatted(), as: .body, colour: row.denied == 0 ? KeyringPalette.ink3 : KeyringPalette.ink)
                    .monospacedDigit()
            }
            .width(56).alignment(.trailing)

            TableColumn(MainWindowCopy.rule, value: \.ruleOrder) { row in
                KeyringRulePill(title: row.rule.name, visual: row.rule.visual)
            }
            .width(126)
        }
        .alternatingRowBackgrounds(.disabled)
    }

    private var emptyState: some View {
        VStack(spacing: KeyringSpace.s3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(KeyringPalette.ink3)
            KeyringText(
                model.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No passwords match these filters"
                    : "No passwords matching “\(model.search)”",
                as: .heading
            )
            if model.ruleFilter != nil || model.categoryFilter != nil || !model.search.isEmpty {
                KeyringButton(.plain("Clear Filters") {
                    model.ruleFilter = nil
                    model.categoryFilter = nil
                    model.search = ""
                })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KeyringPalette.canvas)
    }

    private var footer: some View {
        HStack(spacing: KeyringSpace.s3) {
            KeyringText(
                "Showing \(model.visibleLogins.count.formatted()) of \(model.snapshot.logins.count.formatted()) passwords · \(imported)",
                as: .meta
            )
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.snapshot.copyIsStale || model.snapshot.sampleOnly {
                KeyringButton(.plain(model.snapshot.sampleOnly ? MainWindowCopy.copyFromPasswords : MainWindowCopy.copyAgain, perform: model.importAgain))
            }
        }
        .padding(.horizontal, KeyringSpace.s5)
        .padding(.vertical, KeyringSpace.s2 + 2)
    }

    private var imported: String {
        if model.snapshot.sampleOnly { return MainWindowCopy.sampleOnly }
        guard let at = model.snapshot.importedAt else { return MainWindowCopy.noneCopied }
        let date = at.formatted(.dateTime.day().month(.abbreviated))
        if model.snapshot.copyChangedNothing { return MainWindowCopy.copiedNoChanges(date) }
        return model.snapshot.copyIsStale ? MainWindowCopy.copiedOnStale(date) : MainWindowCopy.copiedOn(date)
    }
}

/// Touch ID confirmation sheet opened immediately when a user selects 1+ rows in Edit Mode and picks a rule.
/// Lists every exact change before one biometric signature, with zero implicit staging state.
public struct MacRuleConfirmSheet: View {
    let confirmation: MacMainModel.RuleConfirmation
    let computers: [String]
    let isWorking: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    public init(
        confirmation: MacMainModel.RuleConfirmation,
        computers: [String],
        isWorking: Bool,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.confirmation = confirmation
        self.computers = computers
        self.isWorking = isWorking
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    private var approveSymbol: String {
        ReviewRendering.isOn
            ? MacApprover.symbol
            : (AccessRequestCopy.approveSymbol(MacApprover.shared.approver) ?? MacApprover.symbol)
    }

    private var changesCount: Int { confirmation.logins.count }

    private var explanation: String {
        switch confirmation.targetRule {
        case .automatic:
            let targets = MainWindowCopy.list([MainWindowCopy.thisMacInSentence] + computers)
            return "Agents on \(targets) will be able to use \(changesCount == 1 ? "this password" : "these \(changesCount) passwords") without asking."
        case .ask:
            return confirmation.plan.needsReimportCount > 0
                ? "Agents will ask you before using these passwords. Previously blocked passwords must be updated from Apple Passwords."
                : "Agents will ask you for Touch ID or Face ID before using \(changesCount == 1 ? "this password" : "these \(changesCount) passwords")."
        case .blocked:
            return changesCount == 1
                ? "Agents can no longer request this password, and its saved copy is removed from Agent Keyring. Apple Passwords is never changed."
                : "Agents can no longer request these \(changesCount) passwords, and their saved copies are removed from Agent Keyring. Apple Passwords is never changed."
        }
    }

    private var hasMixedSourceRules: Bool {
        Set(confirmation.logins.map(\.rule)).count > 1
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s4) {
            VStack(alignment: .leading, spacing: 4) {
                KeyringText(
                    "Set \(changesCount == 1 ? "1 password" : "\(changesCount) passwords") to \(confirmation.targetRule.name)?",
                    as: .title
                )
                KeyringText(explanation, as: .meta)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(confirmation.logins.enumerated()), id: \.element.id) { idx, row in
                        if idx > 0 { Divider() }
                        HStack(spacing: KeyringSpace.s3) {
                            SiteIconView(host: row.site, size: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                KeyringText(row.site, as: .heading, fit: .siteName)
                                    .lineLimit(1)
                                if !row.account.isEmpty {
                                    KeyringText(row.account, as: .meta)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if hasMixedSourceRules {
                                KeyringText("Was \(row.rule.name)", as: .caption, colour: KeyringPalette.ink2)
                                    .fixedSize()
                            }
                        }
                        .padding(.horizontal, KeyringSpace.s3)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: confirmation.logins.count <= 6)
            .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card, style: .continuous))
            .clipShape(.rect(cornerRadius: KeyringRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card, style: .continuous).strokeBorder(KeyringPalette.line))

            HStack(spacing: KeyringSpace.s2) {
                Spacer(minLength: 0)
                KeyringButton(.plain(MainWindowCopy.cancel, isEnabled: !isWorking, perform: onCancel))
                KeyringButton(
                    .approve(
                        isWorking ? MainWindowCopy.useTouchIDToSave : "Confirm & Save",
                        symbol: approveSymbol,
                        isEnabled: !isWorking,
                        perform: onConfirm
                    )
                )
            }
        }
        .padding(KeyringSpace.s5)
        .frame(width: 520)
        .background(KeyringPalette.canvas)
    }
}
#endif
