import Darwin
import Foundation
import Observation

public enum CredentialAccessPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case ask
    case allowAutomatically
    case block

    public var title: String {
        switch self {
        case .ask: "Ask each time"
        case .allowAutomatically: "Allow automatically"
        case .block: "Block"
        }
    }

    public var sortKey: String {
        switch self {
        case .ask: "1-ask"
        case .allowAutomatically: "2-allow"
        case .block: "3-block"
        }
    }
}

public enum CredentialReleaseDecision: Equatable, Sendable {
    case requestAuthorization
    case release
    case block
}

public enum CredentialAccessFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case ask
    case allowAutomatically
    case block

    public var title: String {
        switch self {
        case .all: "All access"
        case .ask: "Ask each time"
        case .allowAutomatically: "Allow automatically"
        case .block: "Blocked"
        }
    }

    fileprivate func includes(_ policy: CredentialAccessPolicy) -> Bool {
        switch self {
        case .all: true
        case .ask: policy == .ask
        case .allowAutomatically: policy == .allowAutomatically
        case .block: policy == .block
        }
    }
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
    public var filter = CredentialAccessFilter.all {
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

    public func refresh(from generation: MirrorGeneration) async {
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

        guard currentGenerationID != generation.id else { return }
        currentGenerationID = generation.id
        let currentIDs = Set(generation.items.map(\.id))
        policies = policies.filter { currentIDs.contains($0.key) }
        rows = generation.items.map { item in
            AccessCredentialRow(
                id: item.id,
                title: item.title,
                account: Self.accountLabel(for: item),
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
        guard !credentialIDs.isEmpty else { return }
        let previousPolicies = policies
        let previousRows = rows
        errorMessage = nil

        for id in credentialIDs {
            if policy == .ask {
                policies.removeValue(forKey: id)
            } else {
                policies[id] = policy
            }
        }
        rows = rows.map { credentialIDs.contains($0.id) ? $0.changingPolicy(to: policy) : $0 }
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
        rows.lazy.filter { $0.policy == policy }.count
    }

    private func recomputeVisibleRows() {
        let query = searchText.foldedForCredentialSearch
        let terms = query.split(separator: " ").map(String.init)
        visibleRows =
            rows
            .filter { filter.includes($0.policy) }
            .filter { row in
                terms.allSatisfy { term in
                    row.searchableText.contains(term)
                        || row.searchableText.isSubsequenceMatch(for: term)
                }
            }
        visibleRows.sort(using: sortOrder)
    }

    private static func accountLabel(for item: MirrorItem) -> String {
        let names = item.credentials.compactMap { credential -> String? in
            switch credential {
            case let .password(userName, _): userName
            case let .totp(_, _, _, userName, _, _): userName
            }
        }.filter { !$0.isEmpty }
        return names.first ?? "No account name"
    }

    private static func websiteLabel(for item: MirrorItem) -> String {
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
