import Foundation
import Observation
import OSLog

private let accessRulesLogger = Logger(subsystem: "com.agentkeyring.app", category: "AccessRules")

public enum CredentialAccessPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case ask
    case allowAutomatically
    case block
}

public enum CredentialReleaseDecision: Equatable, Sendable {
    case needsConfirmation
    case requestAuthorization
    case release
    case block
}

public struct AccessRulesConfirmationRequired: Error, Sendable {
    public static var message: String { "Agent Keyring's access rules need \(MacOwner.firstName)'s confirmation in the app before anything is released." }
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

public struct AccessRulesConfirmationSnapshot: Sendable {
    let policies: [UUID: CredentialAccessPolicy]
    let resetsUnreadableRules: Bool
}

@MainActor
@Observable
public final class CredentialAccessController: PairedDevicePublicKeyProviding {
    public var searchText = "" {
        didSet { recomputeVisibleRows() }
    }
    public var selectedPolicy: CredentialAccessPolicy? = .ask {
        didSet { recomputeVisibleRows() }
    }
    public var sortOrder = [KeyPathComparator(\AccessCredentialRow.title)] {
        didSet { recomputeVisibleRows() }
    }

    public private(set) var hasPairedApprovalDevice = false
    public private(set) var pairedApprovalDevices: [PairedApprovalDevice] = []
    public private(set) var rows: [AccessCredentialRow] = []
    public private(set) var visibleRows: [AccessCredentialRow] = []
    public private(set) var errorMessage: String?
    public private(set) var needsConfirmation = true
    public private(set) var isSavingRules = false
    public private(set) var confirmationResetsUnreadableRules = false
    public private(set) var hasLoadedLoginList = false
    public var canConfirmRules: Bool { needsConfirmation && hasLoadedLoginList && !isSavingRules }
    public var confirmationSummary: String {
        "\(count(for: .allowAutomatically)) allowed automatically, \(count(for: .block)) blocked, \(count(for: .ask)) ask each time"
    }

    private var pendingPhoneBlocks: Set<UUID> = []
    public var pendingPhoneBlockCount: Int { pendingPhoneBlocks.count }
    private let pendingBlocksFile: PendingIPhoneBlocks
    private var pendingBlocksReadError: (any Error)?
    private let store: CredentialAccessPolicyStore
    private var policies: [UUID: CredentialAccessPolicy] = [:]
    private var confirmationSnapshot: AccessRulesConfirmationSnapshot?
    private var currentGenerationID: UUID?

    public init(store: CredentialAccessPolicyStore = CredentialAccessPolicyStore()) {
        self.store = store
        pendingBlocksFile = PendingIPhoneBlocks(rulesFileURL: store.fileURL)
        do { pendingPhoneBlocks = try pendingBlocksFile.load() }
        catch {
            pendingBlocksReadError = error
            errorMessage = "The iPhone blocks could not be read. Confirm your access rules before releasing logins."
            accessRulesLogger.error("Pending iPhone blocks load failed")
        }
    }

    public func pairedDevicePublicKeys() async throws -> [Data] {
        try await store.pairedDevicePublicKeys()
    }

    public func confirmPairing(_ session: IPhonePairingSession, confirmationCode: String) async throws {
        guard !isSavingRules else { throw PairingFailure.invalidRequest }
        isSavingRules = true
        defer { isSavingRules = false }
        try await session.confirm(in: store, confirmationCode: confirmationCode)
        try await reloadRules()
    }

    public func removePairedApprovalDevice(publicKey: Data) async throws {
        guard !isSavingRules else { throw PairedDeviceStoreError.notPaired }
        isSavingRules = true
        defer { isSavingRules = false }
        try await store.removePairedDevice(publicKey: publicKey)
        try await reloadRules()
    }

    public func refresh(from generation: MirrorGeneration?) async {
        await refresh(fromMetadata: generation?.metadata)
    }

    public func refresh(fromMetadata metadata: MirrorMetadata?) async {
        if confirmationSnapshot != nil, hasLoadedLoginList { return }
        if confirmationSnapshot == nil {
            do { try await reloadRules() }
            catch { errorMessage = AccessRulesConfirmationRequired.message }
        }
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
        pendingPhoneBlocks.contains(credentialID) ? .block : policies[credentialID, default: .ask]
    }

    public func releaseDecision(
        for credentialID: UUID,
        field: AgentCredentialField
    ) -> CredentialReleaseDecision {
        guard !needsConfirmation else { return .needsConfirmation }
        return switch policy(for: credentialID) {
        case .block:
            .block
        case .allowAutomatically:
            .release
        case .ask:
            field.requiresUserApproval ? .requestAuthorization : .release
        }
    }

    public func stagePhoneBlock(for credentialID: UUID) {
        pendingPhoneBlocks.insert(credentialID)
        do { try pendingBlocksFile.save(pendingPhoneBlocks) }
        catch {
            errorMessage = "The login is blocked, but its iPhone block could not be saved for restart."
            accessRulesLogger.error("Pending iPhone block save failed")
        }
        CredentialTransfer.revoke(credentialID: credentialID)
        updateRowPolicies()
    }

    public func hasPendingPhoneBlock(for credentialID: UUID) -> Bool {
        pendingPhoneBlocks.contains(credentialID)
    }

    public func setPolicy(_ policy: CredentialAccessPolicy, for credentialIDs: Set<UUID>) async {
        let assignments = Dictionary(uniqueKeysWithValues: credentialIDs.map { ($0, policy) })
        await setPolicies(assignments)
    }

    public func setPolicies(_ assignments: [UUID: CredentialAccessPolicy]) async {
        guard !needsConfirmation else {
            accessRulesLogger.error("Access rule change rejected: confirmation required")
            errorMessage = AccessRulesConfirmationRequired.message
            return
        }
        guard !assignments.isEmpty, !isSavingRules else { return }
        let knownIDs = Set(rows.map(\.id))
        guard assignments.keys.allSatisfy(knownIDs.contains) else {
            errorMessage = "The access change included an unknown credential. No rule was changed."
            return
        }
        var proposedPolicies = policies
        isSavingRules = true
        defer { isSavingRules = false }
        errorMessage = nil

        for (id, policy) in assignments {
            if policy == .block { CredentialTransfer.revoke(credentialID: id) }
            if policy == .ask {
                proposedPolicies.removeValue(forKey: id)
            } else {
                proposedPolicies[id] = policy
            }
        }
        for id in pendingPhoneBlocks where assignments[id] == nil { proposedPolicies[id] = .block }
        do {
            try await store.save(proposedPolicies)
            try await reloadRules()
        } catch {
            errorMessage = "The access change could not be saved. No rule was changed."
        }
    }

    public func ensureRulesConfirmed() async throws {
        guard !needsConfirmation else {
            throw AgentBridgeFailure(.rulesNeedConfirmation, AccessRulesConfirmationRequired.message)
        }
        do {
            guard try await store.load() == policies else { throw AccessRulesConfirmationRequired() }
        } catch {
            throw AgentBridgeFailure(.rulesNeedConfirmation, AccessRulesConfirmationRequired.message)
        }
    }

    public func confirmRules() async {
        guard canConfirmRules, let snapshot = confirmationSnapshot else { return }
        var confirmedPolicies = snapshot.policies
        for id in pendingPhoneBlocks where snapshot.policies[id] == nil { confirmedPolicies[id] = .block }
        let confirmedSnapshot = AccessRulesConfirmationSnapshot(policies: confirmedPolicies,
            resetsUnreadableRules: snapshot.resetsUnreadableRules)
        let reason = "confirm your Agent Keyring access rules: \(confirmationSummary)"
        isSavingRules = true
        defer { isSavingRules = false }
        do {
            try await store.save(confirmedSnapshot, reason: reason)
            pendingBlocksReadError = nil
            confirmationSnapshot = nil
            try await reloadRules()
        } catch {
            needsConfirmation = true
            errorMessage = "Access rules could not be confirmed. Nothing will be released."
        }
    }

    private func reloadRules() async throws {
        hasPairedApprovalDevice = false
        pairedApprovalDevices = []
        do {
            if let pendingBlocksReadError { throw pendingBlocksReadError }
            pendingPhoneBlocks = try pendingBlocksFile.load()
            policies = try await store.load()
            pairedApprovalDevices = try await store.loadPairedDevices()
            hasPairedApprovalDevice = !pairedApprovalDevices.isEmpty
            needsConfirmation = false
            confirmationResetsUnreadableRules = false
            errorMessage = nil
        } catch {
            needsConfirmation = true
            if confirmationSnapshot == nil {
                let snapshot = try await store.snapshotForConfirmation()
                confirmationSnapshot = snapshot
                policies = snapshot.policies
                confirmationResetsUnreadableRules = snapshot.resetsUnreadableRules
            }
            updateRowPolicies()
            throw error
        }
        updateRowPolicies()
    }

    private func updateRowPolicies() {
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
