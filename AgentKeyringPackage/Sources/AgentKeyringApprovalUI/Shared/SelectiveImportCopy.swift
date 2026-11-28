// Written by AI on 2026.11.25 by model gemini-4-neon.
//
// Every user-facing string for Step 2 (Privacy), Step 3 (Selective Import) and
// the manual Add a Password sheet, matching the approved Paper screens.
// Audited automatically by AgentKeyringCopyTests (EveryWordOnScreen).

import AgentKeyringApprovalCore
import Foundation

public struct PrivacyCopyPoint: Identifiable, Sendable {
    public let id: String
    public let symbol: String
    public let heading: String
    public let body: String
}

public enum PrivacyCopy {
    public static let title = "Privacy is important."
    public static let subtitle = "We don’t want to know anything about you. Agent Keyring is designed so we can’t read your passwords, see which sites you use, or track your browsing history."

    public static let points: [PrivacyCopyPoint] = [
        PrivacyCopyPoint(
            id: "devices",
            symbol: "lock.fill",
            heading: "Passwords stay on your devices. Encrypted.",
            body: "Stored on your Mac, iPhone and Apple Watch with keys locked in each device’s Secure Enclave (the chip behind Touch ID). Sync uses your own iCloud, never our servers. We can’t see your passwords or sites, and Apple can’t either."
        ),
        PrivacyCopyPoint(
            id: "e2ee",
            symbol: "checkmark.shield.fill",
            heading: "End-to-end encryption",
            body: "When your AI agent requests a password, you approve it on your Mac, iPhone or Apple Watch. Both the request and the approved password are encrypted with a unique key for that agent, unreadable even on a compromised network."
        ),
        PrivacyCopyPoint(
            id: "zdr",
            symbol: "eye.slash.fill",
            heading: "Zero data retention",
            body: "Approval push notifications travel through our servers end-to-end encrypted. We can’t read the site or password, and we don’t keep any logs or IP addresses. If you only use a Mac, requests never leave your Mac."
        ),
        PrivacyCopyPoint(
            id: "count",
            symbol: "chart.bar.fill",
            heading: "One anonymous user count",
            body: SharedCopy.analyticsDetail + " You can turn it off any time in Settings."
        ),
        PrivacyCopyPoint(
            id: "opensource",
            symbol: "chevron.left.forwardslash.chevron.right",
            heading: "Open source",
            body: "Agent Keyring is open source. You can read the code yourself on GitHub to make sure we’re telling the truth!"
        ),
    ]

    public static let privacyPolicy = "Privacy Policy"
    public static let privacyPolicyURL = URL(string: "https://keyring.opentrawl.sh/privacy/")!
    public static let readSourceCode = "Read the Source Code"
    public static let sourceCodeURL = URL(string: "https://github.com/opentrawl/agent-keyring")!
}

public enum SelectiveImportCopy {
    // MARK: Step 3.1: Choose Starting Point

    public static let chooseTitle = "Which passwords do you want to add to Agent Keyring?"
    public static let chooseSubtitle = "Your AI agents can only ask to use the passwords you pick here. You can always add or remove passwords later."

    public static let pathFewTitle = "Pick a few passwords yourself"
    public static let pathFewDetail = "If you’re just getting started, you can pick a couple of passwords from Apple Passwords to test Agent Keyring out, or add a password manually."

    public static let pathCategoryTitle = "Add passwords by category"
    public static let pathCategoryDetail = "You can pick the types of sites you want your AI agents to use. We’ll import only those ones from Apple Passwords, and you can review everything afterwards."

    public static let pathAllTitle = "Add all of your passwords"
    public static let pathAllDetail = "Apple Passwords sends all of your passwords to Agent Keyring; you can exclude individual passwords before saving. Banking, crypto and government passwords are excluded by default."

    public static let chooseNote = "Your passwords stay encrypted on this Mac. Nothing is changed or deleted in Apple Passwords."
    public static let skipForNow = "Skip for Now (Use Test Password)"

    // MARK: Step 3A: Pick a Few Passwords

    public static let pickFewTitle = "Pick a few passwords yourself"
    public static let pickFewSubtitle = "Export only the passwords you select in Apple Passwords. Nothing in Apple Passwords is changed or deleted."
    public static let inApplePasswordsHeader = "In Apple Passwords"
    public static func guideCounter(_ step: Int, total: Int) -> String { "\(step) of \(total)" }
    public static let pickFewGuide = [
        "Open Apple Passwords. Select a site’s password (or hold ⌘ and click another site to select more), then choose **File › Export Selected Items to App…**",
        "If Apple Passwords says some items will not be exported, click **Continue**, then click **Continue** on **Export Passwords**.",
        "Unlock with Touch ID or your Mac password.",
        "In **Select a Destination**, choose **Agent Keyring** (blue keyhole), then click **Continue**.",
        "Click **Continue in “Agent Keyring”** on the final confirmation sheet.",
    ]
    public static let manualAddHeading = "Or add a password manually"
    public static let manualAddDetail = "Type a website, account and password straight into Agent Keyring."
    public static let addManually = "Add Manually…"
    public static let exportedByMistake = "Exported everything by mistake? Don’t worry, you’ll review the full list before anything is saved."
    public static let addByCategoryInstead = "Add by Category Instead"
    public static let openApplePasswords = "Open Apple Passwords"

    // MARK: Step 3B: Pick Categories

    public static let categoriesTitle = "What kinds of sites should your AI agents use?"
    public static let categoriesSubtitle = "Pick one or more categories.\nAgent Keyring will filter your passwords and only import the sites you picked."
    public static let categoriesFootnote = "Banking, crypto and government passwords are excluded by default. You’ll be able to check the full list of sites before saving anything."
    public static let pickFewInstead = "Pick a Few Passwords Instead"
    public static let addAllInstead = "Add All Instead"

    public static let categoryCodingTitle = "Coding & Cloud"
    public static let categoryCodingExamples = "e.g. GitHub, AWS, Cloudflare, Docker"

    public static let categoryAITitle = "AI & API Tools"
    public static let categoryAIExamples = "e.g. OpenAI, Claude, Cursor, Hugging Face"

    public static let categoryEmailTitle = "Work & Email"
    public static let categoryEmailExamples = "e.g. Gmail, Slack, Zoom, Notion"

    public static let categoryShoppingTitle = "Shopping & Food"
    public static let categoryShoppingExamples = "e.g. Amazon, eBay, IKEA, Deliveroo"

    public static let categoryTravelTitle = "Travel & Transit"
    public static let categoryTravelExamples = "e.g. Booking.com, Airbnb, KLM, Uber"

    public static let categoryMediaTitle = "Media & Gaming"
    public static let categoryMediaExamples = "e.g. Spotify, Netflix, Steam, PlayStation"

    public static let categorySocialTitle = "Social & Community"
    public static let categorySocialExamples = "e.g. YouTube, Reddit, X, LinkedIn"

    public static let categoryHomeTitle = "Home & Devices"
    public static let categoryHomeExamples = "e.g. Philips Hue, Home Assistant, Synology"

    public static let categorySensitiveLabel = "Banking, Crypto & Government"
    public static let categoryOtherLabel = "Other"

    // MARK: Step 3B / 3C: Export from Apple Passwords

    public static let exportBridgeTitle = "Export from Apple Passwords"
    public static let whyExportAllHeading = "Why “Export All Items”?"
    public static func whyExportAllCategoryBody(_ categories: [String]) -> String {
        let joined = MainWindowCopy.list(categories)
        return "Apple Passwords doesn’t support exporting by category, so you’ll export your full list to this Mac. Agent Keyring filters it offline to match your \(joined) passwords."
    }
    public static let whyExportAllAllBody = "Apple Passwords exports your full list straight to Agent Keyring on this Mac. Agent Keyring excludes banking, crypto and government passwords by default."
    public static let whyExportAllGuarantee = "Nothing goes to our servers or any other service. You’ll review the list before saving, Agent Keyring forgets the rest, and your passwords in Apple Passwords stay unchanged."
    public static let inApplePasswordsTitle = "In Apple Passwords"
    public static let exportAllSteps = [
        "1. Choose File › Export All Items to App…",
        "2. Unlock with Touch ID or your Mac password.",
        "3. Select Agent Keyring, then click Continue.",
    ]

    // MARK: Review & Keep

    public static let filteredOfflineBadge = "Filtered offline on this Mac"
    public static func sortingOnDevice(_ count: Int) -> String {
        count == 1
            ? "Sorting 1 more on device with Apple Intelligence…"
            : "Sorting \(count.formatted()) more on device with Apple Intelligence…"
    }
    public static func reviewCategoryTitle(_ selected: Int) -> String {
        selected == 1 ? "We found 1 matching password" : "We found \(selected.formatted()) matching passwords"
    }
    public static func reviewAllTitle(selected: Int, total: Int) -> String {
        "\(selected.formatted()) of \(total.formatted()) passwords selected"
    }
    public static func reviewCategorySummary(total: Int, selected: Int) -> String {
        let kept = selected == 1 ? "this 1 password" : "only these \(selected.formatted()) passwords"
        return "\(total.formatted()) passwords were filtered offline on this Mac. Nothing has been saved yet.\nClick Save to keep \(kept). Agent Keyring will forget the rest, and they stay in Apple Passwords unchanged."
    }
    public static func reviewAllSummary(total: Int, selected: Int, excluded: Int) -> String {
        let excludedText = excluded == 1 ? "the 1 excluded password" : "the \(excluded.formatted()) excluded ones"
        let kept = selected == 1 ? "this 1 password" : "these \(selected.formatted()) passwords"
        if excluded == 0 {
            return "\(total.formatted()) passwords were filtered offline on this Mac. Nothing has been saved yet.\nClick Save to keep \(kept). Your passwords stay in Apple Passwords unchanged."
        }
        return "\(total.formatted()) passwords were filtered offline on this Mac. Nothing has been saved yet.\nClick Save to keep \(kept). Agent Keyring will forget \(excludedText), and everything stays in Apple Passwords unchanged."
    }
    public static func sensitiveBannerTitle(_ count: Int) -> String {
        count == 1
            ? "1 banking, crypto or government password excluded by default"
            : "\(count.formatted()) banking, crypto and government passwords excluded by default"
    }
    public static func sensitiveBannerExamples(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        let shown = Array(names.prefix(4))
        let extra = names.count - shown.count
        if extra > 0 {
            return shown.joined(separator: ", ") + " and \(extra.formatted()) more"
        }
        return MainWindowCopy.list(shown)
    }
    public static func includeAllSensitive(_ count: Int) -> String { "Include All \(count.formatted())" }
    public static let allCategoriesChip = "All"
    public static func tabSelected(_ count: Int) -> String { "Selected (\(count.formatted()))" }
    public static func tabOther(_ count: Int) -> String { "Other (\(count.formatted()))" }
    public static func tabSensitive(_ count: Int) -> String { "Sensitive (\(count.formatted()))" }
    public static let searchPasswords = "Search passwords"
    public static let noSearchMatches = "No passwords match your search."
    public static let noSelectedPasswords = "No passwords selected yet. Tick the ones you want to keep."
    public static let noOtherExcludedPasswords = "No other passwords excluded."
    public static let noSensitiveExcludedPasswords = "No sensitive passwords excluded."
    public static let cancelImport = "Cancel Import"
    public static func savePasswords(_ count: Int) -> String {
        count == 1 ? "Save 1 Password" : "Save \(count.formatted()) Passwords"
    }
    public static let savingPasswords = "Saving…"

    // MARK: Saved Receipt

    public static func receiptTitle(_ count: Int) -> String {
        count == 1 ? "1 password saved on this Mac" : "\(count.formatted()) passwords saved on this Mac"
    }
    public static let receiptSubtitle = "Your original passwords in Apple Passwords haven’t been touched."
    public static let receiptFilteredLabel = "Filtered offline"
    public static let receiptSavedLabel = "Saved on this Mac"
    public static let receiptNotSavedLabel = "Not saved"
    public static let savedPasswordsHeading = "Saved passwords"
    public static func moreSaved(_ count: Int) -> String { "+\(count.formatted()) more" }
    public static func receiptStorageNote(saved: Int, notSaved: Int, isReimport: Bool = false) -> String {
        let kept = saved == 1 ? "This password stays" : "These \(saved.formatted()) passwords stay"
        let forgotten: String
        if notSaved > 0 {
            if isReimport {
                forgotten = " Agent Keyring didn’t save the other \(notSaved.formatted()) passwords from this export, and any passwords you saved earlier stay unchanged."
            } else {
                forgotten = " Agent Keyring forgot the other \(notSaved.formatted()) passwords without saving them, and they stay in Apple Passwords unchanged."
            }
        } else {
            forgotten = ""
        }
        return "\(kept) encrypted on this Mac with keys in the Secure Enclave.\(forgotten) If you connect an iPhone or Apple Watch, only saved passwords sync through your own iCloud."
    }
    public static let receiptApprovalNoteFirstRun = "Your AI agents still have to ask for your approval before using any password. Next, connect an AI agent on this Mac."
    public static let receiptApprovalNoteMain = "New passwords require your approval before an agent can use them. Existing rules stay unchanged, and you can change rules any time in Passwords."
    public static let addMorePasswords = "Add More Passwords…"
    public static let connectAnAgent = "Connect an Agent"
    public static let done = "Done"
}

public enum ManualAddCopy {
    public static let title = "Add a password"
    public static let subtitle = "Saved on this Mac and encrypted with keys in the Secure Enclave. Never sent to our servers."
    public static let websiteLabel = "Website"
    public static let websitePlaceholder = "cloudflare.com"
    public static let accountLabel = "Account"
    public static let accountPlaceholder = "you@example.com"
    public static let passwordLabel = "Password"
    public static let passwordPlaceholder = "Enter password"
    public static let totpLabel = "Two-factor setup key"
    public static let totpPlaceholder = "Optional setup key from the site"
    public static let totpHint = "Paste the setup key shown when turning on 2FA, not a 6-digit code."
    public static let ruleLabel = "Rule"
    public static let ruleNote = "You can change this rule any time in Passwords."
    public static let cancel = "Cancel"
    public static let addPassword = "Add Password"
    public static let adding = "Adding…"
}
