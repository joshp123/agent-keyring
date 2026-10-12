import Darwin
import CryptoKit
import Foundation
import Observation
import OSLog
import Security

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
    let bytes: Data
    let policies: [UUID: CredentialAccessPolicy]
    let resetsUnreadableRules: Bool
}

public actor CredentialAccessPolicyStore: PairedDevicePublicKeyProviding {
    private struct Record: Codable, Equatable {
        let credentialID: UUID
        let policy: CredentialAccessPolicy
    }

    private struct FileContents: Codable, Equatable {
        let version: Int
        let records: [Record]
        let pairedDevices: [PairedApprovalDevice]?

        var policies: [UUID: CredentialAccessPolicy] {
            Dictionary(uniqueKeysWithValues: records.map { ($0.credentialID, $0.policy) })
        }

        var devices: [PairedApprovalDevice] { pairedDevices ?? [] }
    }

    public let fileURL: URL
    public var signatureURL: URL { fileURL.appendingPathExtension("signature") }
    private let fileManager: FileManager
    private let signer: any AccessRulesSigning
    private var isSigning = false

    public init(
        fileURL: URL = CredentialAccessPolicyStore.defaultFileURL(),
        fileManager: FileManager = .default,
        signer: any AccessRulesSigning = SecureEnclaveAccessRulesSigner()
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.signer = signer
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
        try loadVerifiedContents().policies
    }

    public func loadPairedDevices() throws -> [PairedApprovalDevice] {
        try loadVerifiedContents().devices
    }

    public func pairedDevicePublicKeys() throws -> [Data] {
        try loadPairedDevices().map(\.publicKey)
    }

    private func loadVerifiedContents() throws -> FileContents {
        let bytes: Data
        let signature: Data
        do {
            try validateOwnedRegularFile(fileURL)
            try validateOwnedRegularFile(signatureURL)
            bytes = try Data(contentsOf: fileURL)
            signature = try Data(contentsOf: signatureURL)
        } catch {
            accessRulesLogger.error("Access rules load failed: unreadable file")
            throw AccessRulesConfirmationRequired()
        }
        let contents: FileContents
        do { contents = try decodeContents(bytes) }
        catch {
            accessRulesLogger.error("Access rules load failed: decode failure")
            throw AccessRulesConfirmationRequired()
        }
        let validSignature: Bool
        do { validSignature = try signer.verify(signature, for: bytes) }
        catch {
            let nativeError = error as NSError
            if nativeError.domain == NSOSStatusErrorDomain, nativeError.code == Int(errSecItemNotFound) {
                accessRulesLogger.error("Access rules load failed: missing key")
            } else {
                accessRulesLogger.error("Access rules load failed: bad signature")
            }
            throw AccessRulesConfirmationRequired()
        }
        guard validSignature else {
            accessRulesLogger.error("Access rules load failed: bad signature")
            throw AccessRulesConfirmationRequired()
        }
        let signedHash: Data?
        do { signedHash = try signer.signedBytesHash() }
        catch {
            accessRulesLogger.error("Access rules load failed: hash mismatch")
            throw AccessRulesConfirmationRequired()
        }
        guard signedHash == Data(SHA256.hash(data: bytes)) else {
            accessRulesLogger.error("Access rules load failed: hash mismatch")
            throw AccessRulesConfirmationRequired()
        }
        return contents
    }

    public func snapshotForConfirmation() throws -> AccessRulesConfirmationSnapshot {
        // A missing file after rules were once signed is a reset, not a first run.
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return try Self.snapshot([:], resetsUnreadableRules: (try? signer.signedBytesHash()) != nil)
        }
        do {
            try validateOwnedRegularFile(fileURL)
            let bytes = try Data(contentsOf: fileURL)
            let contents = try decodeContents(bytes)
            if contents.devices.isEmpty {
                return AccessRulesConfirmationSnapshot(bytes: bytes, policies: contents.policies, resetsUnreadableRules: false)
            }
            // The rules UI reviews policies, not device keys. It must never bless an injected
            // or rolled-back pairing as a side effect of confirming those policies.
            if (try? loadVerifiedContents()) == contents {
                return AccessRulesConfirmationSnapshot(bytes: bytes, policies: contents.policies, resetsUnreadableRules: false)
            }
            return try Self.snapshot(contents.policies)
        } catch {
            return try Self.snapshot([:], resetsUnreadableRules: true)
        }
    }

    private static func snapshot(_ policies: [UUID: CredentialAccessPolicy], devices: [PairedApprovalDevice] = [],
        resetsUnreadableRules: Bool = false) throws -> AccessRulesConfirmationSnapshot {
        let records = policies.filter { $0.value != .ask }
            .map { Record(credentialID: $0.key, policy: $0.value) }
            .sorted { $0.credentialID.uuidString < $1.credentialID.uuidString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sortedDevices = devices.sorted { $0.publicKey.lexicographicallyPrecedes($1.publicKey) }
        return AccessRulesConfirmationSnapshot(bytes: try encoder.encode(FileContents(version: 2, records: records, pairedDevices: sortedDevices)),
            policies: policies, resetsUnreadableRules: resetsUnreadableRules)
    }

    private func decodeContents(_ bytes: Data) throws -> FileContents {
        let contents = try JSONDecoder().decode(
            FileContents.self,
            from: bytes
        )
        guard (contents.version == 1 && contents.pairedDevices == nil)
            || (contents.version == 2 && contents.pairedDevices != nil)
        else { throw CocoaError(.fileReadCorruptFile) }
        var credentialIDs = Set<UUID>()
        for record in contents.records {
            guard credentialIDs.insert(record.credentialID).inserted else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        var publicKeys = Set<Data>()
        for device in contents.devices {
            guard publicKeys.insert(device.publicKey).inserted,
                (try? P256.Signing.PublicKey(x963Representation: device.publicKey)) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return contents
    }

    public func save(_ policies: [UUID: CredentialAccessPolicy]) async throws {
        var devices: [PairedApprovalDevice] = []
        if fileManager.fileExists(atPath: fileURL.path) {
            try validateOwnedRegularFile(fileURL)
            let contents = try decodeContents(Data(contentsOf: fileURL))
            if !contents.devices.isEmpty { devices = try loadPairedDevices() }
        }
        try await save(try Self.snapshot(policies, devices: devices), reason: "confirm your Agent Keyring access rules")
    }

    public func addPairedDevice(_ device: PairedApprovalDevice) async throws {
        let contents = try loadVerifiedContents()
        guard !contents.devices.contains(where: { $0.publicKey == device.publicKey }) else {
            throw PairedDeviceStoreError.alreadyPaired
        }
        _ = try P256.Signing.PublicKey(x963Representation: device.publicKey)
        try await persist(try Self.snapshot(contents.policies, devices: contents.devices + [device]),
            reason: "pair your iPhone with Agent Keyring")
    }

    public func removePairedDevice(publicKey: Data) async throws {
        let contents = try loadVerifiedContents()
        guard contents.devices.contains(where: { $0.publicKey == publicKey }) else {
            throw PairedDeviceStoreError.notPaired
        }
        try await persist(try Self.snapshot(contents.policies, devices: contents.devices.filter { $0.publicKey != publicKey }),
            reason: "remove your paired iPhone from Agent Keyring")
    }

    public func save(_ snapshot: AccessRulesConfirmationSnapshot, reason: String) async throws {
        let devices = try decodeContents(snapshot.bytes).devices
        let currentDevices = (try? loadVerifiedContents().devices) ?? []
        // A rules confirmation cannot restore a revoked key or add a key that was never paired.
        guard devices.isEmpty || devices == currentDevices else { throw AccessRulesConfirmationRequired() }
        let preservedSnapshot = devices.isEmpty && !currentDevices.isEmpty
            ? try Self.snapshot(snapshot.policies, devices: currentDevices) : snapshot
        try await persist(preservedSnapshot, reason: reason)
    }

    private func persist(_ snapshot: AccessRulesConfirmationSnapshot, reason: String) async throws {
        // Touch ID suspends the actor. A second writer must not sign a stale pairing list.
        guard !isSigning else { throw PairedDeviceStoreError.changeInProgress }
        isSigning = true
        defer { isSigning = false }
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

        if fileManager.fileExists(atPath: fileURL.path) {
            try validateOwnedRegularFile(fileURL)
        }
        let bytes = snapshot.bytes
        let signature = try await signer.sign(bytes, reason: reason)
        if fileManager.fileExists(atPath: signatureURL.path) {
            try validateOwnedRegularFile(signatureURL)
        }
        try bytes.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        try signature.write(to: signatureURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: signatureURL.path
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
    public private(set) var needsConfirmation = true
    public private(set) var isSavingRules = false
    public private(set) var confirmationResetsUnreadableRules = false
    public private(set) var hasLoadedLoginList = false
    public var canConfirmRules: Bool { needsConfirmation && hasLoadedLoginList && !isSavingRules }
    public var confirmationSummary: String {
        "\(count(for: .allowAutomatically)) allowed automatically, \(count(for: .block)) blocked, \(count(for: .ask)) ask each time"
    }

    private let store: CredentialAccessPolicyStore
    private var policies: [UUID: CredentialAccessPolicy] = [:]
    private var confirmationSnapshot: AccessRulesConfirmationSnapshot?
    private var currentGenerationID: UUID?

    public init(store: CredentialAccessPolicyStore = CredentialAccessPolicyStore()) {
        self.store = store
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
        let reason = "confirm your Agent Keyring access rules: \(confirmationSummary)"
        isSavingRules = true
        defer { isSavingRules = false }
        do {
            try await store.save(snapshot, reason: reason)
            confirmationSnapshot = nil
            try await reloadRules()
        } catch {
            needsConfirmation = true
            errorMessage = "Access rules could not be confirmed. Nothing will be released."
        }
    }

    private func reloadRules() async throws {
        do {
            policies = try await store.load()
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
        rows = rows.map { $0.changingPolicy(to: policies[$0.id, default: .ask]) }
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
