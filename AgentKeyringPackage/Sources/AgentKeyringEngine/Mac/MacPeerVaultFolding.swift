// Written by AI on 2026.11.23 by model claude opus 5.5.
//
// The Mac's list and another device's vault from iCloud: its logins, imports
// and deletions fold into this Mac's own (CredentialVaultMerge), so a password exported
// on the iPhone is listed here, and listed again when this Mac signs the
// catalogue. Its rules come only from the signed catalogue (adoptCatalogue).

#if os(macOS)
import AgentKeyringSealing
import Foundation

@available(macOS 26.0, *)
extension MacKeyringEngine {
    /// False when the folded vault could not be saved, so iCloud brings it again.
    func foldPeerVault(_ peer: CredentialVault) async -> Bool {
        guard let device else { return true }
        do {
            let changed = try await device.withSerializedCatalogue { [self] () async throws -> Bool in
                let current = try await store.loadCurrent() ?? StoredVaultSnapshot(id: UUID(), previousSnapshotID: nil, createdAt: .now,
                    sourceExportedAt: .distantPast, scope: .unknown, exporterIdentifier: "icloud", exporterDisplayName: "iCloud",
                    items: [], skippedCredentialCount: 0)
                let folded = current.folding(peer)
                guard folded.vault != current.vault else { return false }
                try await store.save(folded) { $0 }
                status = folded.safeStatus
                leaseLogins = folded.metadata.candidates
                return true
            }
            guard changed else { return true }
            await accessControl.refresh(fromMetadata: try? await store.loadCurrentMetadata())
            sortUnlistedVaultLoginsIfNeeded()
            // What the signed catalogue lists, the other devices hold already: only this Mac's own changes wait to be sent.
            let listed = Set((device.catalogue?.logins ?? []).map(\.loginID))
            if var sent = sentList {
                for login in leaseLogins where listed.contains(login.id.uuidString) { sent[login.id.uuidString] = .some(login.lastModifiedAt) }
                for id in sent.keys where !listed.contains(id) && !leaseLogins.contains(where: { $0.id.uuidString == id }) { sent[id] = nil }
                sentList = sent
            }
            await noteMissingAutomaticCopies()
            KeyringDiagnosticLog.mac.noteDeviceEvent("cloud", "vault-folded", ["passwords": "\(leaseLogins.count)"])
            return true
        } catch {
            KeyringDiagnosticLog.mac.noteDeviceEvent("cloud", "vault-not-folded", ["reason": "\(error)"])
            return false
        }
    }

    func ownVault() async -> CredentialVault? { try? await store.loadCurrent()?.vault }

    /// Apple gave this Mac a push address: shared with the other devices once this Mac has its keys.
    public func registerPush(token: Data, topic: String, production: Bool) {
        pushAddress = (token, topic, production)
        device?.registerPush(token: token, topic: topic, production: production)
    }

    /// A push: CloudKit's, or a computer's request.
    public func receivedPush(_ userInfo: [AnyHashable: Any]) {
        device?.receivedPush(userInfo)
    }
}
#endif
