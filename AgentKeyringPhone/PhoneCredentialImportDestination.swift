import AgentKeyringCredentialImport
import AgentKeyringPhoneVault
import Foundation
import OSLog

@MainActor
protocol PhoneCredentialImportDestination {
    func status() throws -> PhoneVaultStatus?
    func receive(_ batch: MirrorImportBatch) async throws -> PhoneVaultStatus
}

@MainActor
final class EncryptedPhoneImportDestination: PhoneCredentialImportDestination {
    let vault = PhoneVault(directory: URL.applicationSupportDirectory.appending(path: "PhoneVault", directoryHint: .isDirectory))
    let keys = PhoneEnclaveKeys()

    func status() throws -> PhoneVaultStatus? { try vault.status() }

    func receive(_ batch: MirrorImportBatch) async throws -> PhoneVaultStatus {
        let logger = Logger(subsystem: "com.joshpalmer.AgentKeyring.Phone", category: "Vault")
        logger.notice("Loading phone vault public key")
        let publicKey = try keys.vaultPublicKey(createIfMissing: try vault.status() == nil)
        _ = try keys.signingPublicKey()
        logger.notice("Secure Enclave vault and Face ID signing keys ready")
        return try vault.importCredentials(batch, publicKey: publicKey)
    }
}

/// Counts only; used for import stage logging, never persisted as a saved vault.
struct PhoneImportReceipt {
    let loginCount: Int
    let passwordCount: Int
    let codeCount: Int
    let skippedPasskeyCount: Int
    let skippedMissingPasswordCount: Int
    let skippedOtherCount: Int

    init(batch: MirrorImportBatch) {
        loginCount = batch.items.count
        passwordCount = batch.items.reduce(0) { count, item in
            count + item.credentials.filter { if case .password = $0 { true } else { false } }.count
        }
        codeCount = batch.items.reduce(0) { count, item in
            count + item.credentials.filter { if case .totp = $0 { true } else { false } }.count
        }
        skippedPasskeyCount = batch.skippedCredentialSummary?.passkeyCount ?? 0
        skippedMissingPasswordCount = batch.skippedCredentialSummary?.missingPasswordCount ?? 0
        skippedOtherCount = batch.skippedCredentialSummary?.otherCount ?? 0
    }
}
