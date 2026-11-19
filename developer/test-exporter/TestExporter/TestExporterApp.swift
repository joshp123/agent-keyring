// Written by AI on 2026.11.19 by model claude opus 5.5.
//
// A stand-in for Apple's Passwords app when rehearsing Agent Keyring's first
// run: it holds a few made-up logins and exports them through Apple's
// credential exchange, so Apple's own picker appears and Agent Keyring can be
// chosen in it. Nothing is exported until its button is clicked.

import AuthenticationServices
import SwiftUI

@main
struct TestExporterApp: App {
    var body: some Scene {
        Window("Test Exporter", id: "main") { ExportView() }
            .windowResizability(.contentSize)
    }
}

private struct ExportView: View {
    @Environment(\.credentialExportManager) private var exportManager
    @State private var status = ""
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Made-up logins").font(.headline)
            ForEach(MadeUpLogins.items, id: \.id) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                    Text(item.scope?.urls.map(\.absoluteString).joined(separator: ", ") ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Export to Another App…") { Task { await export() } }
                .disabled(isExporting)
            if !status.isEmpty { Text(status).font(.callout).textSelection(.enabled) }
        }
        .padding(20)
        .frame(width: 360, alignment: .leading)
    }

    private func export() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let options = try await exportManager.requestExport(for: nil)
            try await exportManager.exportCredentials(MadeUpLogins.data(options.formatVersion))
            status = "Exported \(MadeUpLogins.items.count) logins."
        } catch {
            status = "Export stopped: \(error.localizedDescription) (\((error as NSError).domain) \((error as NSError).code))"
        }
    }
}

/// Fixed identifiers, so a second export updates the same logins.
enum MadeUpLogins {
    /// RFC 6238's test secret, "12345678901234567890": the expected codes
    /// can be checked with `oathtool --totp -b GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ`.
    static let totpSecret = Data("12345678901234567890".utf8)

    static let items: [ASImportableItem] = [
        login("mail", "Example Mail", sites: ["https://mail.example.com"], user: "test@example.com", password: "made-up-mail-password"),
        login("shop", "Example Shop", sites: ["https://shop.example.com", "https://checkout.example.com"], user: "shopper",
            password: "made-up-shop-password"),
        login("bank", "Example Bank", sites: ["https://bank.example.net"], user: "test-customer", password: "made-up-bank-password",
            totp: .init(secret: totpSecret, period: 30, digits: 6, userName: "test-customer", algorithm: .sha1, issuer: "Example Bank")),
    ]

    static func data(_ version: ASExportedCredentialData.FormatVersion) -> ASExportedCredentialData {
        let account = ASImportableAccount(id: Data("made-up-account".utf8), userName: "test", email: "test@example.com",
            collections: [], items: items)
        return ASExportedCredentialData(accounts: [account], formatVersion: version,
            exporterRelyingPartyIdentifier: "test-exporter.example.com", exporterDisplayName: "Test Exporter", timestamp: .now)
    }

    private static func login(_ id: String, _ title: String, sites: [String], user: String, password: String,
        totp: ASImportableCredential.TOTP? = nil) -> ASImportableItem {
        var credentials: [ASImportableCredential] = [.basicAuthentication(.init(
            userName: .init(id: nil, fieldType: .string, value: user),
            password: .init(id: nil, fieldType: .concealedString, value: password)))]
        if let totp { credentials.append(.totp(totp)) }
        return ASImportableItem(id: Data(id.utf8), created: .now, lastModified: .now, title: title,
            scope: .init(urls: sites.compactMap(URL.init(string:))), credentials: credentials)
    }
}
