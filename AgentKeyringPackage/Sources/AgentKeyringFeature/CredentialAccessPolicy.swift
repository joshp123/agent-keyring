import Foundation
import LocalAuthentication
import Observation
import OSLog

private let accessRulesLogger = Logger(subsystem: "com.agentkeyring.app", category: "AccessRules")

private func rulesFailureMessage(_ error: Error) -> String {
    if let failure = error as? LeaseFailure { return failure.message }
    let native = error as NSError
    if native.domain == LAError.errorDomain {
        switch LAError.Code(rawValue: native.code) {
        case .userCancel, .appCancel, .systemCancel:
            return "Confirmation was interrupted. Try again."
        case .biometryNotAvailable, .companionNotAvailable, .biometryNotEnrolled:
            return "Touch ID or Apple Watch isn't available. Check that one is ready and try again."
        default:
            return "macOS couldn't confirm you. Try again."
        }
    }
    return "Agent Keyring couldn't save the rules. Try again. If it keeps happening, restart Agent Keyring."
}

public enum CredentialAccessPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case ask
    case allowAutomatically
    case block
}

public struct AccessRulesSaveInProgress: Error, LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "Access rules are already being saved. Wait for that save to finish." }
}

public struct AccessCredentialRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let account: String
    public let website: String
    public let policy: CredentialAccessPolicy

    fileprivate var searchableText: String {
        "\(title) \(account) \(website)".foldedForCredentialSearch
    }

    fileprivate func changingPolicy(to policy: CredentialAccessPolicy) -> Self {
        Self(id: id, title: title, account: account, website: website, policy: policy)
    }
}

@MainActor
@Observable
public final class CredentialAccessController {
    /// Runs before a change is saved, with the context Josh approved: seals
    /// or withdraws the Automatic copies and publishes the catalogue.
    var beforeSave: (@MainActor (_ old: [UUID: CredentialAccessPolicy], _ new: [UUID: CredentialAccessPolicy], LAContext) async throws -> Void)?
    var onRulesChanged: (@MainActor () -> Void)?

    public var searchText = "" {
        didSet { recomputeVisibleRows() }
    }
    public var selectedPolicy: CredentialAccessPolicy? = .ask {
        didSet { recomputeVisibleRows() }
    }
    public var sortOrder = [KeyPathComparator(\AccessCredentialRow.title)] {
        didSet { recomputeVisibleRows() }
    }

    public private(set) var rows: [AccessCredentialRow] = []
    public private(set) var visibleRows: [AccessCredentialRow] = []
    public private(set) var errorMessage: String?
    public private(set) var isSavingRules = false
    public private(set) var hasLoadedLoginList = false
    private let store: CredentialAccessPolicyStore
    private var policies: [UUID: CredentialAccessPolicy] = [:]
    private var currentGenerationID: UUID?

    public init(store: CredentialAccessPolicyStore = CredentialAccessPolicyStore()) {
        self.store = store
        do { policies = try store.load() }
        catch { errorMessage = "The saved rules could not be read. Every login asks first until you set them again." }
    }

    public func refresh(from generation: MirrorGeneration?) async {
        await refresh(fromMetadata: generation?.metadata)
    }

    public func refresh(fromMetadata metadata: MirrorMetadata?) async {
        guard let metadata else {
            currentGenerationID = nil
            rows = []
            recomputeVisibleRows()
            return
        }
        guard currentGenerationID != metadata.id
            || Set(rows.map(\.id)) != Set(metadata.candidates.map(\.id)) else { return }
        currentGenerationID = metadata.id
        hasLoadedLoginList = true
        rows = metadata.candidates.map { item in
            AccessCredentialRow(
                id: item.id,
                title: item.title,
                account: item.username ?? "No account name",
                website: Self.websiteLabel(for: item),
                policy: policy(for: item.id)
            )
        }
        recomputeVisibleRows()
    }

    public func policy(for credentialID: UUID) -> CredentialAccessPolicy {
        policies[credentialID, default: .ask]
    }

    /// `context` is one Josh has already approved where he was looking; the
    /// save signs with it and never asks him again.
    public func setPolicy(_ policy: CredentialAccessPolicy, for credentialIDs: Set<UUID>, context: LAContext) async {
        let assignments = Dictionary(uniqueKeysWithValues: credentialIDs.map { ($0, policy) })
        await setPolicies(assignments, context: context)
    }

    public func setPolicies(_ assignments: [UUID: CredentialAccessPolicy], context: LAContext) async {
        guard !assignments.isEmpty, !isSavingRules else { return }
        let knownIDs = Set(rows.map(\.id))
        guard assignments.keys.allSatisfy(knownIDs.contains) else {
            errorMessage = "The access change included an unknown credential. No rule was changed."
            return
        }
        var proposed = policies
        for (id, policy) in assignments { proposed[id] = policy == .ask ? nil : policy }
        guard proposed != policies else { return }
        isSavingRules = true
        defer { isSavingRules = false }
        errorMessage = nil
        do {
            try await beforeSave?(policies, proposed, context)
            try store.save(proposed)
            policies = proposed
            updateRowPolicies()
        } catch {
            errorMessage = rulesFailureMessage(error)
        }
    }

    public var allPolicies: [UUID: CredentialAccessPolicy] { policies }

    private func updateRowPolicies() {
        onRulesChanged?()
        rows = rows.map { $0.changingPolicy(to: policy(for: $0.id)) }
        recomputeVisibleRows()
    }

    public func count(for policy: CredentialAccessPolicy) -> Int {
        rows.lazy.filter { $0.policy == policy && $0.id != MirrorItem.exampleCredentialID }.count
    }

    private func recomputeVisibleRows() {
        guard let selectedPolicy else {
            visibleRows = []
            return
        }
        let query = searchText.foldedForCredentialSearch
        let terms = query.split(separator: " ").map(String.init)
        visibleRows =
            rows
            .filter { $0.policy == selectedPolicy }
            .filter { row in
                terms.allSatisfy { term in
                    row.searchableText.contains(term)
                        || row.searchableText.isSubsequenceMatch(for: term)
                }
            }
        visibleRows.sort(using: sortOrder)
    }

    private static func websiteLabel(for item: CredentialCandidate) -> String {
        let hosts = item.origins.compactMap { URLComponents(string: $0)?.host }
        return hosts.first ?? item.origins.first ?? "No website"
    }
}

private extension String {
    var foldedForCredentialSearch: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    func isSubsequenceMatch(for query: String) -> Bool {
        var iterator = makeIterator()
        for character in query {
            var found = false
            while let candidate = iterator.next() {
                if candidate == character {
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        return true
    }
}
