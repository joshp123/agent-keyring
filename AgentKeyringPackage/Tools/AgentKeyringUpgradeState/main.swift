// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// Seeds dummy 0.2.x state for an actual-app upgrade proof; never bundled.
import AgentKeyringFeature
import CryptoKit
import Foundation
import Security

@main
struct UpgradeState {
    static func main() async {
        do { try await seed() }
        catch {
            FileHandle.standardError.write(Data("Upgrade setup failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func seed() async throws {
        guard CommandLine.arguments.count == 2,
            ["--example-only", "--inspect-example", "--make-legacy", "--clear-test-keychain"].contains(CommandLine.arguments[1]),
            Bundle.main.bundleIdentifier == "com.joshpalmer.AgentKeyring" else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let vault = EncryptedSnapshotStore()
        if CommandLine.arguments[1] == "--clear-test-keychain" {
            guard let generation = try await vault.loadCurrent(), generation.items.count == 1,
                generation.items[0].id == MirrorItem.exampleCredentialID else {
                throw CocoaError(.fileWriteNoPermission)
            }
            for (service, account, protected) in [
                ("com.agentkeyring.authority-checkpoint.v1", "committed-snapshot", true),
                ("AgentKeyring.access-rules.signed-bytes.v1", "latest", true),
                ("com.joshpalmer.AgentKeyring.vault", "snapshot-key", false),
            ] {
                try deleteTestItem([kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                    kSecUseDataProtectionKeychain as String: protected])
            }
            try deleteTestItem([kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: Data("AgentKeyring.access-rules.signing.v1".utf8),
                kSecUseDataProtectionKeychain as String: true])
            print("Removed the mini proof's non-synchronizable task checkpoint, rule signer and vault key.")
            return
        }
        if CommandLine.arguments[1] == "--make-legacy" {
            guard let generation = try await vault.loadCurrent(),
                generation.items.count == 1, generation.items[0].id == MirrorItem.exampleCredentialID else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try await writeLegacyPayload(generation, vault: vault)
            print("Restored the 0.2.5 delta field on the dummy mirror.")
            return
        }
        if CommandLine.arguments[1] == "--inspect-example" {
            let generation = try await vault.loadCurrent()
            let metadata = try await vault.loadCurrentMetadata()
            print("Mirror items: \(generation?.items.count ?? 0); metadata logins: \(metadata?.candidates.count ?? 0)")
            return
        }
        guard try await vault.loadCurrent() == nil else { throw CocoaError(.fileWriteFileExists) }
        let item = MirrorItem(id: MirrorItem.exampleCredentialID,
            sourceIdentity: MirrorSourceIdentity(exporterIdentifier: "com.agentkeyring.example",
                accountID: Data("example@example.com".utf8), itemID: Data("example.com".utf8)),
            title: "example.com", origins: ["https://example.com", "http://127.0.0.1:8443"],
            credentials: [.password(userName: "example@example.com", password: "example-password")])
        let generation = MirrorGeneration(id: UUID(), previousGenerationID: nil,
            createdAt: Date(), sourceExportedAt: Date(), scope: .full,
            exporterIdentifier: "com.agentkeyring.example", exporterDisplayName: "Synthetic upgrade proof",
            items: [item], skippedCredentialCount: 0)
        try await vault.save(generation)
        try await writeLegacyPayload(generation, vault: vault)
        let rulesFile = CredentialAccessPolicyStore.defaultFileURL()
        guard !FileManager.default.fileExists(atPath: rulesFile.path),
            !FileManager.default.fileExists(atPath: rulesFile.appendingPathExtension("signature").path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let legacyRules = Data("{\"version\":1,\"records\":[{\"credentialID\":\"\(item.id.uuidString)\",\"policy\":\"allowAutomatically\"}]}".utf8)
        try legacyRules.write(to: rulesFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rulesFile.path)
        print("Seeded one encrypted example.com login and one unsigned 0.2.x Automatic rule.")
    }

    static func deleteTestItem(_ query: [String: Any]) throws {
        var localOnly = query
        localOnly[kSecAttrSynchronizable as String] = false
        let status = SecItemDelete(localOnly as CFDictionary)
        guard [errSecSuccess, errSecItemNotFound].contains(status) else { throw KeychainError(status: status) }
    }

    static func writeLegacyPayload(_ generation: MirrorGeneration, vault: EncryptedSnapshotStore) async throws {
        var contents = try JSONSerialization.jsonObject(with: JSONEncoder().encode(generation)) as! [String: Any]
        var items = contents["items"] as! [[String: Any]]
        let code = MirrorCredential.totp(secret: Data("12345678901234567890".utf8), period: 30,
            digits: 6, userName: nil, algorithm: .sha1, issuer: "Synthetic upgrade proof")
        var credentials = items[0]["credentials"] as! [[String: Any]]
        if !credentials.contains(where: { $0["totp"] != nil }) {
            credentials.append(try JSONSerialization.jsonObject(with: JSONEncoder().encode(code)) as! [String: Any])
        }
        items[0]["credentials"] = credentials
        contents["items"] = items
        contents["delta"] = ["addedItemIDs": [MirrorItem.exampleCredentialID.uuidString],
            "changedItems": [], "removedItemIDs": []] as [String: Any]
        let plaintext = try JSONSerialization.data(withJSONObject: contents, options: .sortedKeys)
        let ciphertext = try AES.GCM.seal(plaintext, using: KeychainVaultKeyProvider().loadOrCreateKey()).combined!
        try await ciphertext.write(to: vault.generationFileURL(for: generation.id), options: .atomic)
    }
}
