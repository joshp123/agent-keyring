#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringSealing
import Foundation
import LocalAuthentication
import OSLog
import Observation

private let accessRulesLogger = Logger(subsystem: "com.agentkeyring.app", category: "AccessRules")

private func rulesFailureMessage(_ error: Error) -> String {
    if let failure = error as? AgentRPCError { return failure.message }
    let native = error as NSError
    if native.domain == LAError.errorDomain {
        switch LAError.Code(rawValue: native.code) {
        case .userCancel, .appCancel, .systemCancel:
            return MessageCopy.confirmationInterrupted
        case .biometryNotAvailable, .biometryNotPaired, .biometryDisconnected, .companionNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
            return MessageCopy.touchIDUnavailable
        default:
            return MessageCopy.macOSCouldNotConfirm
        }
    }
    return MessageCopy.rulesNotSaved
}

/// The saved rules were read only now: a change worked out before must be worked out again.
struct AccessRulesReadAgain: Error, Sendable {}

struct AccessRulesSaveInProgress: Error, LocalizedError, Sendable {
    init() {}
    var errorDescription: String? { MessageCopy.rulesBeingSaved }
}

public struct AccessCredentialRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let account: String
    public let website: String
    public let rule: LoginRule
    /// Its secret was deleted when it was Blocked: only a new export from Passwords brings it back.
    public var secretDeleted = false

    fileprivate func changingRule(to rule: LoginRule) -> Self {
        Self(id: id, title: title, account: account, website: website, rule: rule, secretDeleted: secretDeleted)
    }
}

@MainActor
@Observable
public final class CredentialAccessController {
    /// Runs before a change is saved, with the context Josh approved: seals
    /// or withdraws the Automatic copies and publishes the catalogue.
    var beforeSave: (@MainActor (_ old: [UUID: LoginRule], _ new: [UUID: LoginRule], LAContext) async throws -> Void)?
    /// Runs once a change is published and saved.
    var afterSave: (@MainActor (_ old: [UUID: LoginRule], _ new: [UUID: LoginRule]) async -> Void)?
    var onRulesChanged: (@MainActor () -> Void)?
    var onRollback: (@MainActor () async -> Void)?

    public private(set) var rows: [AccessCredentialRow] = []
    public private(set) var errorMessage: String?
    private(set) var isSavingRules = false
    private(set) var hasLoadedLoginList = false
    /// This device's key id, which every rule set here carries.
    public var actor = ""
    private let store: LoginRuleStore
    /// Every login's rule with when and where it was set, Ask included.
    public private(set) var entries: [UUID: LoginRuleTimestampEntry] = [:]
    private var rules: [UUID: LoginRule] { entries.compactMapValues { $0.rule == .ask ? nil : $0.rule } }
    private var currentSnapshotID: UUID?
    private let now: () -> Date
    /// The keychain could not be read at launch: nothing is saved over the rules it holds until they are read.
    private(set) var savedRulesLocked = false

    public init(store: LoginRuleStore = LoginRuleStore(), now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        do { entries = try store.loadAccessRules() } catch {
            savedRulesLocked = true
            errorMessage = MessageCopy.rulesUnreadable
        }
    }

    /// Reads the saved rules again after a launch that could not read them. Throws while it still cannot.
    private func readSavedRulesAgain() throws {
        guard savedRulesLocked else { return }
        entries = try store.loadAccessRules()
        savedRulesLocked = false
        if errorMessage == MessageCopy.rulesUnreadable { errorMessage = nil }
        rulesGeneration &+= 1
        updateRowRules()
    }

    public func refresh(from snapshot: StoredVaultSnapshot?) async {
        await refresh(fromMetadata: snapshot?.metadata)
    }

    public func refresh(fromMetadata metadata: MacVaultMetadata?) async {
        guard let metadata else {
            currentSnapshotID = nil
            rows = []
            return
        }
        guard currentSnapshotID != metadata.id
            || Set(rows.map(\.id)) != Set(metadata.candidates.map(\.id))
            || Set(rows.filter(\.secretDeleted).map(\.id)) != Set(metadata.candidates.filter(\.isSecretDeleted).map(\.id)) else { return }
        currentSnapshotID = metadata.id
        hasLoadedLoginList = true
        rows = metadata.candidates.map { item in
            AccessCredentialRow(
                id: item.id,
                title: item.title,
                account: item.username ?? "No account name",
                website: Self.websiteLabel(for: item),
                rule: rule(for: item.id),
                secretDeleted: item.isSecretDeleted
            )
        }
    }

    public func rule(for credentialID: UUID) -> LoginRule {
        entries[credentialID]?.rule ?? .ask
    }

    /// `context` is one Josh has already approved where he was looking; the
    /// save signs with it and never asks him again.
    public func setRule(_ rule: LoginRule, for credentialIDs: Set<UUID>, context: LAContext) async {
        let assignments = Dictionary(uniqueKeysWithValues: credentialIDs.map { ($0, rule) })
        await setRules(assignments, context: context)
    }

    private var rulesGeneration: UInt64 = 0

    public func setRules(_ assignments: [UUID: LoginRule], context: LAContext) async {
        guard !assignments.isEmpty, !isSavingRules else { return }
        do { try readSavedRulesAgain() } catch {
            errorMessage = MessageCopy.rulesUnreadable
            return
        }
        let knownIDs = Set(rows.map(\.id))
        guard assignments.keys.allSatisfy(knownIDs.contains) else {
            errorMessage = MessageCopy.unknownPassword
            return
        }
        let stampedAt = LoginRuleTimestampEntry.nowMs(now())
        var proposed = entries
        for (id, rule) in assignments where self.rule(for: id) != rule {
            proposed[id] = LoginRuleTimestampEntry.set(rule, replacing: entries[id], at: stampedAt, by: actor)
        }
        guard proposed != entries else { return }
        isSavingRules = true
        defer { isSavingRules = false }
        errorMessage = nil
        // The new rules are current while they are sealed and published, so the
        // catalogue the other devices get says them; a failure puts the old back
        // unless an incoming signed catalogue adopted newer rules in the meantime.
        let startGeneration = rulesGeneration
        let previous = entries
        let previousRules = rules
        entries = proposed
        do {
            try await beforeSave?(previousRules, rules, context)
            if rulesGeneration == startGeneration {
                try store.save(proposed)
                updateRowRules()
                await afterSave?(previousRules, rules)
            }
        } catch {
            if rulesGeneration == startGeneration {
                entries = previous
                updateRowRules()
                await onRollback?()
            }
            errorMessage = rulesFailureMessage(error)
        }
    }

    var allRules: [UUID: LoginRule] { rules }

    /// Rules merged from another device, or moved to new IDs by an import:
    /// saved as they are, since the copies they need are already sealed or withdrawn. Throws, keeping the
    /// rules as they were, when they could not be saved, and while the saved rules could not be read: `next`
    /// was worked out without them, so the caller works it out again once they are.
    func adopt(_ next: [UUID: LoginRuleTimestampEntry]) throws {
        if savedRulesLocked {
            try readSavedRulesAgain()
            throw AccessRulesReadAgain()
        }
        guard isSavingRules || next != entries else { return }
        do {
            try store.save(next)
        } catch {
            errorMessage = rulesFailureMessage(error)
            throw error
        }
        entries = next
        rulesGeneration &+= 1
        updateRowRules()
    }

    private func updateRowRules() {
        onRulesChanged?()
        rows = rows.map { $0.changingRule(to: rule(for: $0.id)) }
    }

    public func loginCount(for rule: LoginRule) -> Int {
        rows.lazy.filter { $0.rule == rule }.count
    }

    private static func websiteLabel(for item: CredentialCandidate) -> String {
        let hosts = item.origins.compactMap { URLComponents(string: $0)?.host }
        return hosts.first ?? item.origins.first ?? "No website"
    }

    /// Clears all saved rules and rows in memory and persists an empty ruleset.
    func resetAccessRules() {
        entries = [:]
        currentSnapshotID = nil
        hasLoadedLoginList = false
        rows = []
        errorMessage = nil
        try? store.save([:])
    }
}
#endif
