import Foundation

@available(macOS 26.0, *)
extension MirrorAppModel {
    func makeRelayApprover() -> RelayApprover {
        let approver = RelayApprover(leaseStore: leaseStore, phoneDelay: { [approvalRoutingSettings] in approvalRoutingSettings.phoneDelaySeconds }) { [weak self] in
            guard let self else { throw LeaseFailure(.unavailable, "Agent Keyring is closing.") }
            try await self.accessControl.ensureRulesConfirmed()
            let imported = try await self.store.loadCurrent()
            guard let generation = self.generationIncludingExample(imported) else {
                throw LeaseFailure(.notFound, "Import your logins before publishing them to the relay.")
            }
            // The import is asynchronous. Revalidate the signed rules before
            // reading either passwords or the policy used for this delivery.
            try await self.accessControl.ensureRulesConfirmed()
            return RelayApproverVault(generation: generation,
                policies: Dictionary(uniqueKeysWithValues: generation.items.map { ($0.id, self.accessControl.policy(for: $0.id)) }))
        }
        approver.publicationConfirmationChanged = { [weak accessControl] required in
            accessControl?.needsRelayPublicationConfirmation = required
        }
        return approver
    }
}
