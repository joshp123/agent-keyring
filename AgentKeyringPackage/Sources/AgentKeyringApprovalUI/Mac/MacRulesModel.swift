// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The rules window's view model. The app gives it the logins and a way to
// save rule changes; the view never touches the signed rules store.

import Foundation
import LocalAuthentication
import Observation

public struct LoginRuleRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var site: String
    public var account: String
    public var rule: LoginRule
    public var lastUsed: Date?

    public init(id: UUID, site: String, account: String, rule: LoginRule, lastUsed: Date? = nil) {
        self.id = id
        self.site = site
        self.account = account
        self.rule = rule
        self.lastUsed = lastUsed
    }
}

/// The sidebar: every login, or the logins under one rule.
public enum LoginRuleFilter: Hashable, Sendable {
    case all
    case rule(LoginRule)
}

/// Nothing is shared until Josh confirms the rules with Touch ID: on first
/// use, after an import adds logins, or when the saved rules can't be verified.
public struct RulesConfirmation: Hashable, Sendable {
    /// For example "542 logins: 470 Ask, 60 Automatic, 12 Blocked."
    public var summary: String
    /// The signed rules file couldn't be verified, so confirming saves the
    /// rules shown and the iPhone must be paired again.
    public var savedRulesWereUnreadable: Bool
    public var explanation: String

    public init(summary: String, savedRulesWereUnreadable: Bool, explanation: String? = nil) {
        self.summary = summary
        self.savedRulesWereUnreadable = savedRulesWereUnreadable
        self.explanation = explanation ?? (savedRulesWereUnreadable
            ? RulesCopy.confirmBodyAfterUnreadableRules : RulesCopy.confirmBody)
    }
}

public struct LoginRulesSnapshot: Hashable, Sendable {
    public var rows: [LoginRuleRow]
    public var confirmation: RulesConfirmation?
    /// A confirmed change the relay hasn't acknowledged yet.
    public var isApplying: Bool

    public init(rows: [LoginRuleRow], confirmation: RulesConfirmation?, isApplying: Bool = false) {
        self.rows = rows
        self.confirmation = confirmation
        self.isApplying = isApplying
    }
}

/// Saving rules is signed with a context Josh has already approved in the
/// rules window, so the backend never asks him itself.
@MainActor
public protocol LoginRulesBackend: AnyObject {
    /// The current logins and rules first, then each time they change.
    func updates() -> AsyncStream<LoginRulesSnapshot>
    func setRules(_ rules: [UUID: LoginRule], context: LAContext) async throws
    /// Saves the rules as shown.
    func confirmRules(context: LAContext) async throws
}

@MainActor
@Observable
public final class MacRulesModel {
    public private(set) var rows: [LoginRuleRow]
    public private(set) var confirmation: RulesConfirmation?
    public private(set) var isApplying: Bool
    public private(set) var isConfirming = false
    public var filter: LoginRuleFilter = .rule(.ask)
    public var searchText = ""
    public var selection = Set<UUID>()
    public var sortOrder = [KeyPathComparator(\LoginRuleRow.site)]
    public private(set) var failure: String?
    #if os(macOS)
    /// Set while a change waits for Touch ID or Apple Watch in this window.
    public private(set) var approval: OwnerApproval?
    #endif
    public var openAssistant: () -> Void = {}

    private let backend: any LoginRulesBackend

    public init(backend: any LoginRulesBackend, initial: LoginRulesSnapshot) {
        self.rows = initial.rows
        self.confirmation = initial.confirmation
        self.isApplying = initial.isApplying
        self.backend = backend
    }

    /// Follows the backend while the window is open. Call from `.task`.
    public func followUpdates() async {
        for await snapshot in backend.updates() {
            rows = snapshot.rows
            confirmation = snapshot.confirmation
            isApplying = snapshot.isApplying
        }
    }

    #if os(macOS)
    public func confirmRules() {
        isConfirming = true
        ask(action: RulesCopy.confirmAction, perform: { [backend] context in try await backend.confirmRules(context: context) },
            done: { [weak self] approved in
                self?.isConfirming = false
                if approved { self?.confirmation = nil }
            })
    }
    #endif

    public func count(_ filter: LoginRuleFilter) -> Int {
        switch filter {
        case .all: rows.count
        case let .rule(rule): rows.lazy.filter { $0.rule == rule }.count
        }
    }

    public var visibleRows: [LoginRuleRow] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return rows
            .filter { row in
                if case let .rule(rule) = filter, row.rule != rule { return false }
                return query.isEmpty || row.site.lowercased().contains(query) || row.account.lowercased().contains(query)
            }
            .sorted(using: sortOrder)
    }

    #if os(macOS)
    public func setRule(_ rule: LoginRule, for ids: Set<UUID>) {
        setRules(Dictionary(uniqueKeysWithValues: ids.map { ($0, rule) }))
    }

    /// Shows the change at once and asks for approval in the window; puts the
    /// rows back if Josh cancels.
    public func setRules(_ rules: [UUID: LoginRule]) {
        guard !rules.isEmpty else { return }
        approval?.cancel()
        let previous = rows
        let changed = rows.filter { rules[$0.id] != nil }
        guard changed.count == rules.count else {
            failure = "The login list changed. Review the rules and try again."
            return
        }
        for index in rows.indices { if let rule = rules[rows[index].id] { rows[index].rule = rule } }
        let sites = rows.filter { rules[$0.id] != nil }.map(\.site)
        var note = changed.map { "\($0.site) — \($0.account): \(rules[$0.id]!.name)" }.joined(separator: "\n")
        if changed.contains(where: { $0.rule != .automatic && rules[$0.id] == .automatic }) {
            note += "\nIf this Mac is connected to your Mac mini: " + RulesCopy.automaticStoredOnMini
        }
        ask(action: RulesCopy.changeAction(sites: sites, to: Set(rules.values).count == 1 ? rules.values.first : nil),
            note: note,
            perform: { [backend] context in try await backend.setRules(rules, context: context) },
            done: { [weak self] approved in if !approved { self?.rows = previous } })
    }

    private func ask(action: String, note: String? = nil, perform: @escaping @MainActor (LAContext) async throws -> Void,
        done: @escaping @MainActor (Bool) -> Void) {
        approval?.cancel()
        approval = OwnerApproval(action: action, note: note, reason: action, perform: perform) { [weak self] approved in
            self?.approval = nil
            done(approved)
        }
    }
    #endif

    public func dismissFailure() { failure = nil }
}
