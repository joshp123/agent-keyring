import AgentKeyringCredentialImport
import Foundation

/// R4.2 implements this by sealing and additively merging the batch before
/// returning .saved. The batch includes secrets; never log or persist it here.
@MainActor
protocol PhoneCredentialImportDestination {
    func receive(_ batch: MirrorImportBatch) async throws -> PhoneCredentialImportDisposition
}

enum PhoneCredentialImportDisposition {
    case receivedOnly
    case saved(totalLoginCount: Int, at: Date)
}

/// R4.1 proves Apple's hand-off without writing an unprotected phone vault.
/// Only counts survive this call. The screen explicitly says to export again
/// once encrypted storage is available.
struct ReceiptOnlyPhoneImportDestination: PhoneCredentialImportDestination {
    func receive(_ batch: MirrorImportBatch) async throws -> PhoneCredentialImportDisposition {
        .receivedOnly
    }
}

/// Safe to retain across launches: no tokens, identifiers, names or secrets.
struct PhoneImportReceipt: Codable {
    let receivedAt: Date
    let loginCount: Int
    let passwordCount: Int
    let codeCount: Int
    let skippedPasskeyCount: Int
    let skippedMissingPasswordCount: Int
    let skippedOtherCount: Int

    init(batch: MirrorImportBatch) {
        receivedAt = Date()
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

    var receivedOnlyMessage: String {
        "Received \(loginCount) logins: \(passwordCount) passwords and \(codeCount) verification codes. "
        + "Skipped \(skippedPasskeyCount) passkeys, \(skippedMissingPasswordCount) entries without passwords and \(skippedOtherCount) unsupported credentials. "
        + "This import-check build has not saved the logins. Export again after the phone vault is ready."
    }
}
