// Written by AI on 2026.11.25 by model gemini-4-neon; split into step views on 2026.11.27 by model claude opus 5.5.
//
// Selective Import Review & Keep step: every received password in one of three
// disjoint tabs (Selected, Other, Sensitive), with search and category pills.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

/// Which of the three disjoint review lists is showing.
enum MacImportReviewTab: Hashable {
    case selected, other, sensitive
}

/// What the review step shows, taken from `MacSelectiveImportStep.review`.
struct MacImportReviewContent {
    let items: [MacReviewPasswordRow]
    let isCategoryMode: Bool
    let sensitiveExcludedCount: Int
    let isSaving: Bool
    let sortingRemainingCount: Int
}

struct MacImportReviewStep: View {
    let state: MacSelectiveImportState
    let actions: MacSelectiveImportPageActions
    let review: MacImportReviewContent
    // Kept by the step itself, so every review starts on Selected with no search, whatever the last one showed.
    @State private var reviewTab: MacImportReviewTab = .selected
    @State private var searchText: String = ""

    private var selectedCount: Int { review.items.filter(\.isSelected).count }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var body: some View {
        MacImportStepPage(scrollBody: false) {
            titleBlock
            // Live in-memory category & All selector wrapping cleanly into 2 rows with zero clipping.
            scopePills
            // Three disjoint sets: Selected + Other + Sensitive == total received.
            tabAndSearchBar
            reviewList

            if let status = state.status {
                KeyringStatusLine(status)
            }
        } footer: {
            KeyringButton(.plain(SelectiveImportCopy.cancelImport, isEnabled: !review.isSaving, perform: actions.cancelImport))
            Spacer(minLength: KeyringSpace.s2)
            KeyringButton(.advance(
                review.isSaving ? SelectiveImportCopy.savingPasswords : SelectiveImportCopy.savePasswords(selectedCount),
                isEnabled: selectedCount > 0 && !review.isSaving,
                perform: actions.saveSelected
            ))
        }
    }

    private var titleBlock: some View {
        let total = review.items.count
        let title = review.isCategoryMode
            ? SelectiveImportCopy.reviewCategoryTitle(selectedCount)
            : SelectiveImportCopy.reviewAllTitle(selected: selectedCount, total: total)
        let summary = review.isCategoryMode
            ? SelectiveImportCopy.reviewCategorySummary(total: total, selected: selectedCount)
            : SelectiveImportCopy.reviewAllSummary(total: total, selected: selectedCount, excluded: total - selectedCount)
        return VStack(alignment: .leading, spacing: KeyringSpace.s1) {
            HStack(alignment: .center) {
                KeyringText(title, as: .title)
                Spacer(minLength: 0)
                if review.sortingRemainingCount > 0 {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        KeyringText(SelectiveImportCopy.sortingOnDevice(review.sortingRemainingCount), as: .meta)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(KeyringPalette.fill, in: .capsule)
                }
            }
            KeyringText(summary, as: .meta)
        }
    }

    private var scopePills: some View {
        ImportChipFlow(horizontalSpacing: 6, verticalSpacing: 6) {
            scopePill(
                title: SelectiveImportCopy.allCategoriesChip,
                selected: !review.isCategoryMode,
                action: actions.switchToAllPasswords
            )
            ForEach(MacImportCategoryOption.defaults) { option in
                scopePill(
                    title: option.title,
                    selected: review.isCategoryMode && state.selectedCategories.contains(option.id)
                ) {
                    actions.toggleCategory(option.id)
                }
            }
        }
    }

    private var tabAndSearchBar: some View {
        let otherExcludedCount = review.items.filter { !$0.isSelected && !$0.isSensitive }.count
        return HStack(spacing: KeyringSpace.s2) {
            Picker("", selection: $reviewTab) {
                Text(SelectiveImportCopy.tabSelected(selectedCount)).tag(MacImportReviewTab.selected)
                Text(SelectiveImportCopy.tabOther(otherExcludedCount)).tag(MacImportReviewTab.other)
                Text(SelectiveImportCopy.tabSensitive(review.sensitiveExcludedCount)).tag(MacImportReviewTab.sensitive)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .layoutPriority(1)

            TextField(SelectiveImportCopy.searchPasswords, text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 110, idealWidth: 150, maxWidth: 170)
        }
    }

    private var reviewList: some View {
        let shownRows = rowsInCurrentTab
        return ScrollView {
            LazyVStack(spacing: 0) {
                if shownRows.isEmpty {
                    KeyringText(emptyListText, as: .meta)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(KeyringSpace.s6)
                } else {
                    ForEach(Array(shownRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        reviewRow(row)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card))
        .clipShape(.rect(cornerRadius: KeyringRadius.card))
        .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card).strokeBorder(KeyringPalette.line))
    }

    private var rowsInCurrentTab: [MacReviewPasswordRow] {
        let query = searchQuery
        return review.items.filter { row in
            let tabMatches: Bool = switch reviewTab {
            case .selected: row.isSelected
            case .other: !row.isSelected && !row.isSensitive
            case .sensitive: !row.isSelected && row.isSensitive
            }
            guard tabMatches else { return false }
            guard !query.isEmpty else { return true }
            return row.displayName.lowercased().contains(query)
                || row.host.lowercased().contains(query)
                || row.account.lowercased().contains(query)
                || (row.categoryLabel?.lowercased().contains(query) ?? false)
        }
    }

    private var emptyListText: String {
        if !searchQuery.isEmpty { return SelectiveImportCopy.noSearchMatches }
        return switch reviewTab {
        case .selected: SelectiveImportCopy.noSelectedPasswords
        case .other: SelectiveImportCopy.noOtherExcludedPasswords
        case .sensitive: SelectiveImportCopy.noSensitiveExcludedPasswords
        }
    }

    private func scopePill(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            KeyringText(title, as: .caption, colour: selected ? KeyringPalette.brand : KeyringPalette.ink2)
                .fontWeight(selected ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(selected ? KeyringPalette.brandTint : KeyringPalette.fill, in: .capsule)
                .overlay(Capsule().strokeBorder(selected ? KeyringPalette.brand.opacity(0.35) : KeyringPalette.line))
        }
        .buttonStyle(.plain)
        .disabled(review.isSaving)
    }

    private func reviewRow(_ row: MacReviewPasswordRow) -> some View {
        Button {
            actions.toggleReviewItem(row.id)
        } label: {
            HStack(alignment: .center, spacing: KeyringSpace.s2) {
                Image(systemName: row.isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(row.isSelected ? KeyringPalette.brand : KeyringPalette.ink3)
                    .accessibilityHidden(true)

                SiteIconView(host: row.host, displayName: row.displayName, size: 22)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        KeyringText(row.displayName, as: .label, colour: KeyringPalette.ink)
                            .lineLimit(1)
                        if row.host.caseInsensitiveCompare(row.displayName) != .orderedSame {
                            KeyringText(row.host, as: .caption)
                                .lineLimit(1)
                        }
                    }
                    if !row.account.isEmpty {
                        KeyringText(row.account, as: .caption)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let categoryLabel = row.categoryLabel {
                    KeyringText(categoryLabel, as: .pictureText, colour: row.isSensitive ? KeyringPalette.stalled : KeyringPalette.ink2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(row.isSensitive ? KeyringPalette.stalledTint : KeyringPalette.fill, in: .capsule)
                        .fixedSize()
                }
            }
            .padding(.horizontal, KeyringSpace.s3)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(review.isSaving)
    }
}

/// Wrapping flow layout for review category filter pills so every pill stays on screen.
private struct ImportChipFlow: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            widest = max(widest, x + size.width)
            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
#endif
