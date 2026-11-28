// Written by AI on 2026.11.18 by model Claude Opus 5.5; rebuilt on 2026.11.26
// by model gemini-4-neon; split into its own file on 2026.11.27 by model claude opus 5.5.
//
// Passwords tab: Rule-grouped passwords (full-width emails, zero truncation),
// plain-text category filter, and native multi-select Edit Mode with a bottom
// Set Rule bar.

#if os(iOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

private struct PhoneCategoryMeta: Identifiable {
    let id: String
    let title: String

    /// All 10 real buckets (Option B: plain text + tabular count, zero category icons).
    static let all: [PhoneCategoryMeta] = [
        .init(id: "codingCloud", title: SelectiveImportCopy.categoryCodingTitle),
        .init(id: "aiTools", title: SelectiveImportCopy.categoryAITitle),
        .init(id: "emailWork", title: SelectiveImportCopy.categoryEmailTitle),
        .init(id: "shopping", title: SelectiveImportCopy.categoryShoppingTitle),
        .init(id: "travelTransit", title: SelectiveImportCopy.categoryTravelTitle),
        .init(id: "mediaGaming", title: SelectiveImportCopy.categoryMediaTitle),
        .init(id: "socialMedia", title: SelectiveImportCopy.categorySocialTitle),
        .init(id: "homeDevices", title: SelectiveImportCopy.categoryHomeTitle),
        .init(id: "sensitive", title: "Sensitive"),
        .init(id: "other", title: SelectiveImportCopy.categoryOtherLabel),
    ]

    static func title(for id: String) -> String {
        all.first { $0.id == id }?.title ?? SelectiveImportCopy.categoryOtherLabel
    }
}

/// Passwords: grouped into three native Rule sections (Always Allowed, Ask First, Blocked) so every row
/// gets 100% full width for Site + Account with zero truncated usernames and zero repeated rule pills.
/// Native toolbar Edit enters multi-select with a bottom Set Rule bar (replacing the tab bar) + Face ID sheet.
struct PhoneLoginsView: View {
    @Bindable var model: PhoneModel
    @State private var query = ""
    @State private var expandedRules: Set<LoginRule> = [.automatic, .ask, .blocked]

    private let sectionOrder: [LoginRule] = [.automatic, .ask, .blocked]

    private func toggleSection(_ rule: LoginRule) {
        withAnimation(.snappy(duration: 0.2)) {
            if expandedRules.contains(rule) {
                expandedRules.remove(rule)
            } else {
                expandedRules.insert(rule)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Native 44pt Category filter row (Option B: plain text + tabular counts, zero category icons).
                Section {
                    Picker(selection: $model.categoryFilter) {
                        Text("All Categories (\(model.snapshot.logins.count.formatted()))").tag(String?.none)
                        ForEach(PhoneCategoryMeta.all) { cat in
                            Text("\(cat.title) (\(categoryCount(cat.id).formatted()))").tag(String?.some(cat.id))
                        }
                    } label: {
                        KeyringText("Category", as: .body)
                    }
                    .frame(minHeight: 44)
                }
                .listRowBackground(KeyringPalette.surface)

                if visibleLogins.isEmpty {
                    Section {
                        VStack(spacing: KeyringSpace.s2) {
                            KeyringText("No passwords match", as: .heading)
                            if model.categoryFilter != nil || !trimmedQuery.isEmpty {
                                Button("Clear Filters") {
                                    model.categoryFilter = nil
                                    query = ""
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, KeyringSpace.s4)
                    }
                    .listRowBackground(KeyringPalette.surface)
                } else {
                    ForEach(sectionOrder, id: \.self) { rule in
                        let rows = visibleLogins.filter { $0.rule == rule }
                        if !rows.isEmpty {
                            let isExpanded = expandedRules.contains(rule)
                            Section {
                                if isExpanded {
                                    ForEach(rows) { login in
                                        passwordRow(login)
                                    }
                                }
                            } header: {
                                Button {
                                    toggleSection(rule)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: rule.visual.symbol)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(rule.visual.tint)
                                            .accessibilityHidden(true)
                                        KeyringText(PhoneCopy.rule(rule), as: .sectionName, colour: rule.visual.tint)
                                        KeyringText(rows.count.formatted(), as: .meta, colour: KeyringPalette.ink2)
                                            .monospacedDigit()
                                        Spacer(minLength: 8)
                                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(KeyringPalette.ink2)
                                            .accessibilityHidden(true)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .textCase(nil)
                            }
                            .listRowBackground(KeyringPalette.surface)
                        }
                    }
                }

                if !model.isEditingRules {
                    Section {
                        NavigationLink { PhoneCopyPasswordsPage(model: model, inFirstRun: false) } label: {
                            KeyringText(PhoneCopy.copyFromPasswords, colour: KeyringPalette.brand)
                        }
                    } footer: {
                        KeyringText(copied, as: .caption)
                    }
                    .listRowBackground(KeyringPalette.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(KeyringPalette.canvas)
            .navigationTitle(model.isEditingRules ? (model.selectedForEdit.isEmpty ? "Select Passwords" : "\(model.selectedForEdit.count) Selected") : PhoneCopy.passwords)
            .navigationBarTitleDisplayMode(model.isEditingRules ? .inline : .large)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: PhoneCopy.search)
            .toolbar(model.isEditingRules ? .hidden : .visible, for: .tabBar)
            .toolbar {
                if model.isEditingRules {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(PhoneCopy.cancel) {
                            model.endEditingRules()
                        }
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") {
                            model.beginEditingRules()
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.isEditingRules {
                    editBottomRuleBar
                }
            }
            .sheet(item: $model.ruleConfirmation) { confirmation in
                PhoneRuleConfirmSheet(
                    confirmation: confirmation,
                    isWorking: model.isChangingRuleOrDevice,
                    onCancel: { model.cancelRuleChange() },
                    onConfirm: { Task { await model.confirmRuleChange() } }
                )
            }
            .navigationDestination(item: $model.detailLoginID) { loginID in
                PhonePasswordDetailView(model: model, loginID: loginID)
            }
            .navigationDestination(isPresented: $model.showCopyPasswords) {
                PhoneCopyPasswordsPage(model: model, inFirstRun: false)
            }
        }
    }

    @ViewBuilder private func passwordRow(_ login: PhoneLogin) -> some View {
        if model.isEditingRules {
            let checked = model.selectedForEdit.contains(login.id)
            Button {
                model.toggleEditSelection(login.id)
            } label: {
                HStack(alignment: .center, spacing: KeyringSpace.s3) {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(checked ? KeyringPalette.brand : KeyringPalette.ink3)
                        .accessibilityHidden(true)
                    SiteIconView(host: login.site, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        KeyringText(login.site, as: .heading, fit: .siteName)
                        if !login.account.isEmpty {
                            KeyringText(login.account, as: .meta)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(checked ? KeyringPalette.brandTint.opacity(0.45) : KeyringPalette.surface)
        } else {
            NavigationLink {
                PhonePasswordDetailView(model: model, loginID: login.id)
            } label: {
                // Full-width Site + Account (zero trailing rule pill squeezing emails!).
                HStack(alignment: .center, spacing: KeyringSpace.s3) {
                    SiteIconView(host: login.site, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        KeyringText(login.site, as: .heading, fit: .siteName)
                        if !login.account.isEmpty {
                            KeyringText(login.account, as: .meta)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 3)
            }
        }
    }

    /// Bottom Set Rule bar replacing the tab bar during native multi-select Edit Mode (44pt touch targets).
    private var editBottomRuleBar: some View {
        let hasSelection = !model.selectedForEdit.isEmpty
        return VStack(spacing: 8) {
            KeyringText(
                hasSelection ? "Move \(model.selectedForEdit.count) selected to:" : "Tap passwords above to change their rule",
                as: .meta
            )
            HStack(spacing: KeyringSpace.s2) {
                ForEach([LoginRule.ask, .automatic, .blocked], id: \.self) { rule in
                    Button {
                        model.requestRuleChange(rule)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: rule.visual.symbol)
                                .font(.system(size: 11, weight: .semibold))
                            KeyringText(PhoneCopy.rule(rule), as: .caption, colour: hasSelection ? rule.visual.tint : KeyringPalette.ink3)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                        .padding(.horizontal, 8)
                        .foregroundStyle(hasSelection ? rule.visual.tint : KeyringPalette.ink3)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(hasSelection ? rule.visual.tintBackground : KeyringPalette.fill, in: Capsule(style: .circular))
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasSelection || model.isChangingRuleOrDevice)
                }
            }
        }
        .padding(.horizontal, KeyringSpace.s4)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func categoryCount(_ id: String) -> Int {
        model.snapshot.logins.lazy.filter { ($0.categoryID ?? "other") == id }.count
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var visibleLogins: [PhoneLogin] {
        model.snapshot.logins.filter { login in
            let catOK = model.categoryFilter == nil || (login.categoryID ?? "other") == model.categoryFilter
            let queryOK = trimmedQuery.isEmpty
                || login.site.localizedCaseInsensitiveContains(trimmedQuery)
                || login.account.localizedCaseInsensitiveContains(trimmedQuery)
            return catOK && queryOK
        }
        .sorted { ($0.asked, $0.site.lowercased()) > ($1.asked, $1.site.lowercased()) }
    }

    private var copied: String {
        let copy = model.snapshot.passwordsCopy
        guard let at = copy.copiedAt else { return PhoneCopy.notCopiedYet }
        return copy.isStale ? PhoneCopy.copiedOnStale(at) : PhoneCopy.copiedOn(at)
    }
}
#endif
