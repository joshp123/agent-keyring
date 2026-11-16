import AgentKeyringFeature
import Foundation
import LocalAuthentication

/// Exercise the same initial confirmation and later policy-edit paths as the app.
public func confirmInitialAccessRules(in store: CredentialAccessPolicyStore,
    policies: [UUID: CredentialAccessPolicy] = [:]) async throws {
    let snapshot = try await store.snapshotForConfirmation()
    try await store.save(snapshot, reason: "confirm test access rules", context: LAContext())
    if !policies.isEmpty { try await store.save(policies, context: LAContext()) }
}
