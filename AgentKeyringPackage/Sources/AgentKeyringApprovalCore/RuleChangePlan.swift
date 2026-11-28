// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// What changing the rule of the logins Josh picked will do, worked out once
// for the Mac and the iPhone before he confirms it. Blocked deletes every
// copy of a password and ends every grant of it; a login whose password was
// deleted keeps no password under any other rule until a new export from
// Apple Passwords brings it back; leaving Always Allowed ends the grants that
// rule gave without asking. The Mac's lease store and the iPhone's catalogue
// do the same when the change is saved (CredentialLeaseStore.reconcile,
// MacKeyringEngine.deleteSecrets, PhoneKeyringEngine.setLoginRule).

import Foundation

/// A login he picked, as it is now.
public struct RuleChangePlanLogin<LoginID: Hashable & Sendable>: Hashable, Sendable {
    public let id: LoginID
    public var rule: LoginRule
    /// This device holds its password: it is not Blocked, and was not deleted when it was.
    public var holdsSecret: Bool
    /// Grants of it an agent is using or collecting now.
    public var activeLeases: Int
    /// Of those, the ones Always Allowed gave without asking.
    public var automaticLeases: Int

    public init(id: LoginID, rule: LoginRule, holdsSecret: Bool, activeLeases: Int = 0, automaticLeases: Int = 0) {
        self.id = id; self.rule = rule; self.holdsSecret = holdsSecret
        self.activeLeases = activeLeases; self.automaticLeases = automaticLeases
    }
}

public struct RuleChangePlan<LoginID: Hashable & Sendable>: Hashable, Sendable {

    public let target: LoginRule
    /// The picked logins whose rule changes, in the order picked.
    public let affectedLoginIDs: [LoginID]
    /// Passwords Blocked deletes from every device.
    public let willDeleteSecretsCount: Int
    /// Logins that will have no password under the new rule until he exports again from Apple Passwords.
    public let needsReimportCount: Int
    /// Grants the change ends at once.
    public let willRevokeLeasesCount: Int

    /// Nothing he picked changes.
    public var isNoOp: Bool { affectedLoginIDs.isEmpty }

    public init(target: LoginRule, selected: [RuleChangePlanLogin<LoginID>]) {
        self.target = target
        let affected = selected.filter { $0.rule != target }
        affectedLoginIDs = affected.map(\.id)
        switch target {
        case .blocked:
            willDeleteSecretsCount = affected.filter(\.holdsSecret).count
            needsReimportCount = 0
            willRevokeLeasesCount = affected.reduce(0) { $0 + $1.activeLeases }
        case .ask, .automatic:
            willDeleteSecretsCount = 0
            needsReimportCount = affected.filter { !$0.holdsSecret }.count
            willRevokeLeasesCount = target == .automatic ? 0
                : affected.filter { $0.rule == .automatic }.reduce(0) { $0 + $1.automaticLeases }
        }
    }
}
