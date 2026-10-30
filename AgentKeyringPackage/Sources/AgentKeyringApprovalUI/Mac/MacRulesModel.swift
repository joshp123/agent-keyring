// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The rules window's view model. The app gives it the logins and a way to
// save rule changes; the view never touches the signed rules store.

import Foundation
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

/// Saving rules needs Josh's confirmation (Touch ID) and can fail.
@MainActor
public protocol LoginRulesBackend: AnyObject {
    func setRule(_ rule: LoginRule, for loginIDs: Set<UUID>) async throws
}

@MainActor
@Observable
public final class MacRulesModel {
    public private(set) var rows: [LoginRuleRow]
    public var filter: LoginRuleFilter = .rule(.ask)
    public var searchText = ""
    public var selection = Set<UUID>()
    public var sortOrder = [KeyPathComparator(\LoginRuleRow.site)]
    public private(set) var failure: String?
    public var openAssistant: () -> Void = {}

    private let backend: any LoginRulesBackend

    public init(rows: [LoginRuleRow], backend: any LoginRulesBackend) {
        self.rows = rows
        self.backend = backend
    }

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

    public func setRule(_ rule: LoginRule, for ids: Set<UUID>) async {
        let previous = rows
        for index in rows.indices where ids.contains(rows[index].id) {
            rows[index].rule = rule
        }
        do { try await backend.setRule(rule, for: ids) }
        catch {
            rows = previous
            failure = "Rules weren't saved: \(error.localizedDescription)"
        }
    }

    public func dismissFailure() { failure = nil }
}
