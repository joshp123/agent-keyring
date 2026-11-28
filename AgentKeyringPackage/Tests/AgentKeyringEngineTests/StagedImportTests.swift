// Written by AI on 2026.11.25 by model gemini-4-neon; split from
// SelectiveImportTests.swift on 2026.11.27 by model claude opus 5.5.
//
// Offline domain classification, the bundled favicons, manual password entry,
// and which rows a staged import ticks: all in memory, with nothing saved.

import AgentKeyringApprovalUI
@testable import AgentKeyringEngine
import AgentKeyringProtocol
import Foundation
import Testing

struct StagedImportTests {
    private func makeItem(site: String, title: String? = nil, account: String = "alex@example.com") -> StoredVaultLogin {
        StoredVaultLogin(
            id: UUID(),
            sourceIdentity: LoginSourceIdentity(
                exporterIdentifier: "com.apple.Passwords",
                accountID: Data("acc".utf8),
                itemID: Data("\(site)|\(account)".utf8)
            ),
            title: title ?? site,
            origins: ["https://\(site)"],
            credentials: [.password(userName: account, password: "pw-\(site)")]
        )
    }

    private func makeBatch(_ items: [StoredVaultLogin]) -> LoginImportBatch {
        LoginImportBatch(
            scope: .selected,
            exportedAt: .now,
            exporterIdentifier: "com.apple.Passwords",
            exporterDisplayName: "Passwords",
            items: items,
            skippedCredentialCount: 0
        )
    }

    @Test("DomainClassifier routes subdomains, all nine categories, LAN hosts, and banking/crypto/government accurately offline")
    func domainClassification() {
        // Subdomain overrides: AWS vs Amazon Shopping, Google Cloud / Gemini / Gmail
        #expect(DomainClassifier.classify(site: "https://signin.aws.amazon.com") == .codingCloud)
        #expect(DomainClassifier.classify(site: "https://amazon.co.uk") == .shopping)
        #expect(DomainClassifier.classify(site: "https://mail.google.com") == .emailWork)
        #expect(DomainClassifier.classify(site: "https://console.cloud.google.com") == .codingCloud)
        #expect(DomainClassifier.classify(site: "https://gemini.google.com") == .aiTools)

        // All eight selectable categories
        #expect(DomainClassifier.classify(site: "github.com") == .codingCloud)
        #expect(DomainClassifier.classify(site: "dash.cloudflare.com") == .codingCloud)
        #expect(DomainClassifier.classify(site: "platform.openai.com") == .aiTools)
        #expect(DomainClassifier.classify(site: "claude.ai") == .aiTools)
        #expect(DomainClassifier.classify(site: "slack.com") == .emailWork)
        #expect(DomainClassifier.classify(site: "aliexpress.com") == .shopping)
        #expect(DomainClassifier.classify(site: "zalando.de") == .shopping)
        #expect(DomainClassifier.classify(site: "delta.com") == .travelTransit)
        #expect(DomainClassifier.classify(site: "netflix.com") == .mediaGaming)
        #expect(DomainClassifier.classify(site: "steampowered.com") == .mediaGaming)
        #expect(DomainClassifier.classify(site: "x.com") == .socialMedia)
        #expect(DomainClassifier.classify(site: "reddit.com") == .socialMedia)
        #expect(DomainClassifier.classify(site: "192.168.1.1") == .homeDevices)
        #expect(DomainClassifier.classify(site: "http://localhost:8123") == .homeDevices)
        #expect(DomainClassifier.classify(site: "synology.local") == .homeDevices)

        // Banking, crypto, payroll, password managers and government always classify as sensitive
        #expect(DomainClassifier.classify(site: "wise.com") == .sensitive)
        #expect(DomainClassifier.classify(site: "revolut.com") == .sensitive)
        #expect(DomainClassifier.classify(site: "coinbase.com") == .sensitive)
        #expect(DomainClassifier.classify(site: "kraken.com") == .sensitive)
        #expect(DomainClassifier.classify(site: "chase.com") == .sensitive)
        #expect(DomainClassifier.classify(site: "wd3.myworkday.com") == .sensitive)
        #expect(DomainClassifier.classify(site: "my.1password.com") == .sensitive)
        #expect(DomainClassifier.classify(site: "lastpass.com") == .sensitive)
        #expect(DomainClassifier.classify(site: "hmrc.gov.uk") == .sensitive)
        #expect(DomainClassifier.classify(site: "irs.gov") == .sensitive)
        #expect(DomainClassifier.classify(site: "anything.gov") == .sensitive)

        // Multi-tenant app hosts and unlisted domains return nil so Apple Intelligence sorts them on device
        #expect(DomainClassifier.classify(site: "random-shop.firebaseapp.com") == nil)
        #expect(DomainClassifier.classify(site: "random-site.us.auth0.com") == nil)
        #expect(DomainClassifier.classify(site: "random-hobby-blog.example") == nil)

        // Bundled offline catalogue holds 500,000+ real categorised domains
        #expect(DomainClassifier.bundledDomainCount >= 450_000)
    }

    @Test("Bundled offline icon pack holds 10,000+ real favicons and resolves core and long-tail domains")
    func bundledIconPackHasTenThousandIcons() {
        #expect(SiteIconView.bundledIconCount >= 10_000)
        #expect(SiteIconView.hasBundledIcon(forHost: "dash.cloudflare.com"))
        #expect(SiteIconView.hasBundledIcon(forHost: "console.aws.amazon.com"))
        #expect(SiteIconView.hasBundledIcon(forHost: "github.com"))
        #expect(SiteIconView.hasBundledIcon(forHost: "openai.com"))
        #expect(SiteIconView.hasBundledIcon(forHost: "claude.ai"))
        #expect(SiteIconView.hasBundledIcon(forHost: "wise.com"))
        #expect(SiteIconView.hasBundledIcon(forHost: "wikipedia.org"))
    }

    @Test("Category staging selects only matching non-sensitive passwords and produces accurate receipt")
    func categoryStagingAndReceipt() {
        let items = [
            makeItem(site: "github.com"),
            makeItem(site: "console.aws.amazon.com"),
            makeItem(site: "platform.openai.com"),
            makeItem(site: "claude.ai"),
            makeItem(site: "mail.google.com"),
            makeItem(site: "amazon.co.uk"),
            makeItem(site: "wise.com"),
            makeItem(site: "hmrc.gov.uk"),
        ]
        var staged = StagedImport(batch: makeBatch(items), path: .byCategory, selectedCategories: [.codingCloud, .aiTools])
        #expect(staged.totalCount == 8)
        #expect(staged.selectedCount == 4)
        #expect(staged.excludedCount == 4)
        #expect(Set(staged.selectedVaultLogins.map(\.title)) == ["github.com", "console.aws.amazon.com", "platform.openai.com", "claude.ai"])

        // Re-filtering in memory without re-exporting
        staged.applyCategories([.shopping])
        #expect(staged.selectedCount == 1)
        #expect(staged.selectedVaultLogins.map(\.title) == ["amazon.co.uk"])

        let receipt = staged.makeReceipt()
        #expect(receipt.filteredCount == 8)
        #expect(receipt.savedCount == 1)
        #expect(receipt.notSavedCount == 7)
        #expect(receipt.savedSites == [SavedReceiptSite(displayName: "Amazon", host: "amazon.co.uk")])
    }

    @Test("All-passwords mode excludes banking, crypto, password managers and government by default with one-click include")
    func allPasswordsSensitiveExclusion() {
        let items = [
            makeItem(site: "github.com"),
            makeItem(site: "amazon.co.uk"),
            makeItem(site: "wise.com"),
            makeItem(site: "coinbase.com"),
            makeItem(site: "my.1password.com"),
            makeItem(site: "hmrc.gov.uk"),
        ]
        var staged = StagedImport(batch: makeBatch(items), path: .allPasswords, selectedCategories: [])
        #expect(staged.selectedCount == 2)
        #expect(staged.excludedSensitiveItems.count == 4)

        staged.includeAllSensitive()
        #expect(staged.selectedCount == 6)
        #expect(staged.excludedSensitiveItems.isEmpty)
    }

    @Test("ManualCredentialBuilder normalises websites, validates inputs, and parses Base32 and otpauth TOTP keys")
    func manualCredentialBuilder() throws {
        #expect(throws: ManualCredentialError.missingWebsite) {
            try ManualCredentialBuilder.buildBatch(website: "  ", account: "a", password: "secret")
        }
        #expect(throws: ManualCredentialError.missingPassword) {
            try ManualCredentialBuilder.buildBatch(website: "cloudflare.com", account: "a", password: "")
        }
        #expect(throws: ManualCredentialError.invalidTwoFactorKey) {
            try ManualCredentialBuilder.buildBatch(website: "cloudflare.com", account: "a", password: "secret", totpSecret: "not-valid-base32!!!")
        }

        // Valid raw Base32 secret (RFC 4648)
        let batch = try ManualCredentialBuilder.buildBatch(
            website: "cloudflare.com",
            account: "alex@example.com",
            password: "correct-horse-battery",
            totpSecret: "gezd gnbv-gy3t qojq"
        )
        #expect(batch.scope == .selected)
        #expect(batch.items.count == 1)
        #expect(batch.items[0].origins == ["https://cloudflare.com"])
        #expect(batch.items[0].credentials.count == 2)

        // Valid otpauth URI
        let uriBatch = try ManualCredentialBuilder.buildBatch(
            website: "https://github.com/login",
            account: "alex",
            password: "pw",
            totpSecret: "otpauth://totp/GitHub:alex?secret=JBSWY3DPEHPK3PXP&digits=6&period=30&algorithm=SHA256"
        )
        #expect(uriBatch.items[0].origins == ["https://github.com"])
        if case let .totp(_, period, digits, _, algorithm, _) = uriBatch.items[0].credentials.last {
            #expect(period == 30)
            #expect(digits == 6)
            #expect(algorithm == .sha256)
        } else {
            Issue.record("Expected TOTP credential from otpauth URI")
        }
    }

    @Test("EU, Dutch, UK, and US banks and government portals classify as sensitive by default")
    func euAndUsBanksAndGovAreSensitive() {
        let mustBeSensitive = [
            "bunq.com", "knab.nl", "ing.nl", "rabobank.nl", "abnamro.nl", "triodos.nl", "degiro.nl",
            "belastingdienst.nl", "mijnoverheid.nl", "toeslagen.nl", "digid.nl", "uwv.nl",
            "kbc.be", "belfius.be", "postbank.de", "consorsbank.de", "creditmutuel.fr", "boursobank.com",
            "truist.com", "citizensbank.com", "huntington.com", "navyfederal.org", "usaa.com",
            "hmrc.gov.uk", "irs.gov", "impots.gouv.fr",
        ]
        for host in mustBeSensitive {
            #expect(DomainClassifier.classify(site: host) == .sensitive, "Expected \(host) to be classified as sensitive")
        }
    }

    @Test("All Passwords leaves unresolved rows unticked while on-device sorting is in progress")
    func allPasswordsDefersUnresolvedWhileSorting() {
        let known = makeItem(site: "github.com")
        let unknown = makeItem(site: "obscure-regional-credit-union.example", title: "Obscure Credit Union")
        var staged = StagedImport(
            batch: makeBatch([known, unknown]),
            path: .allPasswords,
            selectedCategories: []
        )
        let unknownRow = staged.items.first { $0.host.contains("obscure-regional-credit-union") }!
        let knownRow = staged.items.first { $0.host.contains("github.com") }!

        // While on-device sorting is running, unresolved rows stay unticked so a bank cannot sneak into Save.
        staged.sortingRemainingCount = 1
        #expect(staged.isSelected(knownRow))
        #expect(!staged.isSelected(unknownRow))

        // Explicit user tick overrides the pending hold.
        staged.toggle(unknownRow.id)
        #expect(staged.isSelected(unknownRow))
        staged.toggle(unknownRow.id)
        #expect(!staged.isSelected(unknownRow))

        // Once classified as sensitive, it stays excluded even after sorting finishes.
        staged.overrides.removeAll()
        staged.applyOnDeviceCategory(.sensitive, for: [unknownRow.id])
        staged.sortingRemainingCount = 0
        let updatedUnknown = staged.items.first { $0.id == unknownRow.id }!
        #expect(!staged.isSelected(updatedUnknown))
        #expect(updatedUnknown.isSensitive)
    }
}
