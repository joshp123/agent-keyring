import Darwin
import Foundation
import Observation

public enum CredentialAccessPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case ask
    case allowAutomatically
    case block
}

public enum CredentialReleaseDecision: Equatable, Sendable {
    case requestAuthorization
    case release
    case block
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

public actor CredentialAccessPolicyStore {
    private struct Record: Codable, Equatable {
        let credentialID: UUID
        let policy: CredentialAccessPolicy
    }

    private struct FileContents: Codable, Equatable {
        let version: Int
        let records: [Record]
    }

    public let fileURL: URL
    private let fileManager: FileManager

    public init(
        fileURL: URL = CredentialAccessPolicyStore.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport =
            fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return
            applicationSupport
            .appendingPathComponent("AgentKeyring", isDirectory: true)
            .appendingPathComponent("access-policies.json", isDirectory: false)
    }

    public func load() throws -> [UUID: CredentialAccessPolicy] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        try validateOwnedRegularFile(fileURL)
        let contents = try JSONDecoder().decode(
            FileContents.self,
            from: Data(contentsOf: fileURL)
        )
        guard contents.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        var policies = [UUID: CredentialAccessPolicy]()
        for record in contents.records {
            guard policies.updateValue(record.policy, forKey: record.credentialID) == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return policies
    }

    public func save(_ policies: [UUID: CredentialAccessPolicy]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )

        let records =
            policies
            .filter { $0.value != .ask }
            .map { Record(credentialID: $0.key, policy: $0.value) }
            .sorted { $0.credentialID.uuidString < $1.credentialID.uuidString }
        let contents = FileContents(version: 1, records: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if fileManager.fileExists(atPath: fileURL.path) {
            try validateOwnedRegularFile(fileURL)
        }
        try encoder.encode(contents).write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func validateOwnedRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            let owner = attributes[.ownerAccountID] as? NSNumber,
            owner.uint32Value == getuid()
        else {
            throw CocoaError(.fileReadNoPermission)
        }
    }
}

@MainActor
@Observable
public final class CredentialAccessController {
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

    private let store: CredentialAccessPolicyStore
    private var policies: [UUID: CredentialAccessPolicy] = [:]
    private var currentGenerationID: UUID?
    private var loadedPolicies = false

    public init(store: CredentialAccessPolicyStore = CredentialAccessPolicyStore()) {
        self.store = store
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
        if !loadedPolicies {
            do {
                policies = try await store.load()
                loadedPolicies = true
            } catch {
                errorMessage =
                    "Access rules could not be opened. Credentials will ask for approval."
                policies = [:]
            }
        }

        guard currentGenerationID != metadata.id
            || Set(rows.map(\.id)) != Set(metadata.candidates.map(\.id)) else { return }
        currentGenerationID = metadata.id
        let currentIDs = Set(metadata.candidates.map(\.id))
        policies = policies.filter { currentIDs.contains($0.key) }
        rows = metadata.candidates.map { item in
            AccessCredentialRow(
                id: item.id,
                title: item.title,
                account: item.username ?? "No account name",
                website: Self.websiteLabel(for: item),
                policy: policies[item.id, default: .ask]
            )
        }
        recomputeVisibleRows()
    }

    public func policy(for credentialID: UUID) -> CredentialAccessPolicy {
        policies[credentialID, default: .ask]
    }

    public func releaseDecision(
        for credentialID: UUID,
        field: AgentCredentialField
    ) -> CredentialReleaseDecision {
        switch policy(for: credentialID) {
        case .block:
            .block
        case .allowAutomatically:
            .release
        case .ask:
            field.requiresUserApproval ? .requestAuthorization : .release
        }
    }

    public func setPolicy(_ policy: CredentialAccessPolicy, for credentialIDs: Set<UUID>) async {
        let assignments = Dictionary(uniqueKeysWithValues: credentialIDs.map { ($0, policy) })
        await setPolicies(assignments)
    }

    public func setPolicies(_ assignments: [UUID: CredentialAccessPolicy]) async {
        guard !assignments.isEmpty else { return }
        let knownIDs = Set(rows.map(\.id))
        guard assignments.keys.allSatisfy(knownIDs.contains) else {
            errorMessage = "The access change included an unknown credential. No rule was changed."
            return
        }
        let previousPolicies = policies
        let previousRows = rows
        errorMessage = nil

        for (id, policy) in assignments {
            if policy == .block { CredentialTransfer.revoke(credentialID: id) }
            if policy == .ask {
                policies.removeValue(forKey: id)
            } else {
                policies[id] = policy
            }
        }
        rows = rows.map { row in
            guard let policy = assignments[row.id] else { return row }
            return row.changingPolicy(to: policy)
        }
        recomputeVisibleRows()

        do {
            try await store.save(policies)
        } catch {
            policies = previousPolicies
            rows = previousRows
            recomputeVisibleRows()
            errorMessage = "The access change could not be saved. No rule was changed."
        }
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
