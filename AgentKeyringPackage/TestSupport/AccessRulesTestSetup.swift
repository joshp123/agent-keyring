import AgentKeyringFeature
import Foundation

/// Exercise the same initial confirmation and later policy-edit paths as the app.
public func confirmInitialAccessRules(in store: CredentialAccessPolicyStore,
    policies: [UUID: CredentialAccessPolicy] = [:]) async throws {
    let snapshot = try await store.snapshotForConfirmation()
    try await store.save(snapshot, reason: "confirm test access rules")
    if !policies.isEmpty { try await store.save(policies) }
}
