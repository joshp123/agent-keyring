// Written by AI on 2026.11.25 by model gemini-4-neon; split into its own file on 2026.11.27 by model claude opus 5.5.
//
// Value types the Selective Import screens show: categories, review rows,
// the saved receipt and the page state.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import Foundation

public struct MacImportCategoryOption: Identifiable, Hashable, Sendable {
    public let id: ImportCategory
    public let title: String
    public let symbol: String
    public let examples: String
    public let exampleDomains: [String]

    public init(id: ImportCategory, title: String, symbol: String = "folder.fill", examples: String, exampleDomains: [String]) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.examples = examples
        self.exampleDomains = exampleDomains
    }

    public static let defaults: [MacImportCategoryOption] = [
        .init(
            id: .codingCloud,
            title: SelectiveImportCopy.categoryCodingTitle,
            symbol: "chevron.left.forwardslash.chevron.right",
            examples: SelectiveImportCopy.categoryCodingExamples,
            exampleDomains: ["github.com", "aws.amazon.com", "cloudflare.com", "docker.com"]
        ),
        .init(
            id: .aiTools,
            title: SelectiveImportCopy.categoryAITitle,
            symbol: "cpu",
            examples: SelectiveImportCopy.categoryAIExamples,
            exampleDomains: ["openai.com", "claude.ai", "cursor.com", "huggingface.co"]
        ),
        .init(
            id: .emailWork,
            title: SelectiveImportCopy.categoryEmailTitle,
            symbol: "briefcase.fill",
            examples: SelectiveImportCopy.categoryEmailExamples,
            exampleDomains: ["mail.google.com", "slack.com", "zoom.us", "notion.so"]
        ),
        .init(
            id: .shopping,
            title: SelectiveImportCopy.categoryShoppingTitle,
            symbol: "bag.fill",
            examples: SelectiveImportCopy.categoryShoppingExamples,
            exampleDomains: ["amazon.com", "ebay.com", "ikea.com", "deliveroo.co.uk"]
        ),
        .init(
            id: .travelTransit,
            title: SelectiveImportCopy.categoryTravelTitle,
            symbol: "airplane",
            examples: SelectiveImportCopy.categoryTravelExamples,
            exampleDomains: ["booking.com", "airbnb.com", "klm.com", "uber.com"]
        ),
        .init(
            id: .mediaGaming,
            title: SelectiveImportCopy.categoryMediaTitle,
            symbol: "play.rectangle.fill",
            examples: SelectiveImportCopy.categoryMediaExamples,
            exampleDomains: ["spotify.com", "netflix.com", "steampowered.com", "playstation.com"]
        ),
        .init(
            id: .socialMedia,
            title: SelectiveImportCopy.categorySocialTitle,
            symbol: "bubble.left.and.bubble.right.fill",
            examples: SelectiveImportCopy.categorySocialExamples,
            exampleDomains: ["youtube.com", "reddit.com", "x.com", "linkedin.com"]
        ),
        .init(
            id: .homeDevices,
            title: SelectiveImportCopy.categoryHomeTitle,
            symbol: "house.fill",
            examples: SelectiveImportCopy.categoryHomeExamples,
            exampleDomains: ["philips-hue.com", "home-assistant.io", "synology.com", "ui.com"]
        ),
    ]

    public static let nineCategories: [(id: ImportCategory, title: String, symbol: String)] =
        defaults.map { ($0.id, $0.title, $0.symbol) } + [
            (.sensitive, "Sensitive", "shield.lefthalf.filled"),
        ]

    public static let sidebarItems: [(id: ImportCategory, title: String, symbol: String)] =
        nineCategories + [
            (.other, SelectiveImportCopy.categoryOtherLabel, "ellipsis.circle"),
        ]

    public static func title(for category: ImportCategory) -> String {
        sidebarItems.first { $0.id == category }?.title ?? SelectiveImportCopy.categoryOtherLabel
    }
}

public struct MacReviewPasswordRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let displayName: String
    public let host: String
    public let account: String
    public let categoryLabel: String?
    public let isSelected: Bool
    public let isSensitive: Bool

    public init(
        id: UUID,
        displayName: String,
        host: String,
        account: String,
        categoryLabel: String?,
        isSelected: Bool,
        isSensitive: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.account = account
        self.categoryLabel = categoryLabel
        self.isSelected = isSelected
        self.isSensitive = isSensitive
    }
}

public struct MacImportReceiptSite: Equatable, Hashable, Sendable {
    public let displayName: String
    public let host: String

    public init(displayName: String, host: String) {
        self.displayName = displayName
        self.host = host
    }
}

public struct MacImportReceiptData: Equatable, Sendable {
    public let filteredCount: Int
    public let savedCount: Int
    public let notSavedCount: Int
    public let savedSites: [MacImportReceiptSite]
    public let isReimport: Bool

    public init(
        filteredCount: Int,
        savedCount: Int,
        notSavedCount: Int,
        savedSites: [MacImportReceiptSite],
        isReimport: Bool = false
    ) {
        self.filteredCount = filteredCount
        self.savedCount = savedCount
        self.notSavedCount = notSavedCount
        self.savedSites = savedSites
        self.isReimport = isReimport
    }
}

public enum MacSelectiveImportStep: Equatable, Sendable {
    case choose
    case pickFew(guideStep: Int)
    case pickCategories
    case exportBridge(selectedCategoryTitles: [String], isAllPasswords: Bool)
    case review(
        items: [MacReviewPasswordRow],
        isCategoryMode: Bool,
        sensitiveExcludedCount: Int,
        sensitiveExcludedExamples: [String],
        isSaving: Bool,
        sortingRemainingCount: Int = 0
    )
    case receipt(MacImportReceiptData)
    case syncingFromDevice(from: String)
    case syncedFromDevice(count: Int, from: String)
}

public struct MacSelectiveImportState: Equatable, Sendable {

    public var step: MacSelectiveImportStep
    public var chosenPath: ImportPath
    public var selectedCategories: Set<ImportCategory>
    public var status: KeyringStatus?
    public var isBusy: Bool
    public var inFirstRun: Bool

    public init(
        step: MacSelectiveImportStep,
        chosenPath: ImportPath = .pickFew,
        selectedCategories: Set<ImportCategory> = [.codingCloud, .aiTools],
        status: KeyringStatus? = nil,
        isBusy: Bool = false,
        inFirstRun: Bool = true
    ) {
        self.step = step
        self.chosenPath = chosenPath
        self.selectedCategories = selectedCategories
        self.status = status
        self.isBusy = isBusy
        self.inFirstRun = inFirstRun
    }
}
#endif
