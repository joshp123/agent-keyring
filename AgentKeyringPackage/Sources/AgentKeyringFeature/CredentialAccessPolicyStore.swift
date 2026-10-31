import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import OSLog
import Security

private let accessRulesStoreLogger = Logger(subsystem: "com.agentkeyring.app", category: "AccessRules")

@MainActor public final class CredentialAccessPolicyStore: PairedDevicePublicKeyProviding {
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
    var authority: CredentialLeaseStore?
    var authorizeSave: (@MainActor (LAContext, String) async throws -> Void)?
    var commitSave: (@MainActor ([UUID: CredentialAccessPolicy], CredentialLeaseStore.SavedRules, LAContext) async throws -> Void)?

    private enum PairedDeviceChange {
        case add(PairedApprovalDevice)
        case remove(Data)
    }

    public init(
        fileURL: URL = CredentialAccessPolicyStore.defaultFileURL(),
        fileManager: FileManager = .default,
        signer: any AccessRulesSigning = SecureEnclaveAccessRulesSigner()
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.signer = signer
    }

    nonisolated public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
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
        try authority?.load()
        if let saved = authority?.savedRules { return try decodeContents(saved.bytes) }
        let bytes: Data
        let signature: Data
        do {
            try validateOwnedRegularFile(fileURL)
            try validateOwnedRegularFile(signatureURL)
            bytes = try Data(contentsOf: fileURL)
            signature = try Data(contentsOf: signatureURL)
        } catch {
            accessRulesStoreLogger.error("Access rules load failed: unreadable file")
            throw AccessRulesConfirmationRequired()
        }
        let contents: FileContents
        do { contents = try decodeContents(bytes) }
        catch {
            accessRulesStoreLogger.error("Access rules load failed: decode failure")
            throw AccessRulesConfirmationRequired()
        }
        let validSignature: Bool
        do { validSignature = try signer.verify(signature, for: bytes) }
        catch {
            let nativeError = error as NSError
            if nativeError.domain == NSOSStatusErrorDomain, nativeError.code == Int(errSecItemNotFound) {
                accessRulesStoreLogger.error("Access rules load failed: missing key")
            } else {
                accessRulesStoreLogger.error("Access rules load failed: bad signature")
            }
            throw AccessRulesConfirmationRequired()
        }
        guard validSignature else {
            accessRulesStoreLogger.error("Access rules load failed: bad signature")
            throw AccessRulesConfirmationRequired()
        }
        let signedHash: Data?
        do { signedHash = try signer.signedBytesHash() }
        catch {
            accessRulesStoreLogger.error("Access rules load failed: hash mismatch")
            throw AccessRulesConfirmationRequired()
        }
        guard signedHash == Data(SHA256.hash(data: bytes)) else {
            accessRulesStoreLogger.error("Access rules load failed: hash mismatch")
            throw AccessRulesConfirmationRequired()
        }
        return contents
    }

    public func snapshotForConfirmation() throws -> AccessRulesConfirmationSnapshot {
        let contents: FileContents?
        do {
            try validateOwnedRegularFile(fileURL)
            contents = try decodeContents(Data(contentsOf: fileURL))
        } catch {
            contents = nil
        }
        let reason: AccessRulesConfirmationReason
        if !fileManager.fileExists(atPath: fileURL.path), !fileManager.fileExists(atPath: signatureURL.path) {
            reason = .firstUse
        } else if contents?.version == 1, !fileManager.fileExists(atPath: signatureURL.path) {
            reason = .upgrade
        } else {
            reason = .unverified
        }
        return AccessRulesConfirmationSnapshot(policies: contents?.policies ?? [:], reason: reason,
            requiresPhonePairingAgain: contents?.devices.isEmpty == false)
    }

    private static func encodedContents(_ policies: [UUID: CredentialAccessPolicy], devices: [PairedApprovalDevice]) throws -> Data {
        let records = policies.filter { $0.value != .ask }
            .map { Record(credentialID: $0.key, policy: $0.value) }
            .sorted { $0.credentialID.uuidString < $1.credentialID.uuidString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sortedDevices = devices.sorted { $0.publicKey.lexicographicallyPrecedes($1.publicKey) }
        return try encoder.encode(FileContents(version: 2, records: records, pairedDevices: sortedDevices))
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
        try await persist(policies: policies, reason: "confirm your Agent Keyring access rules")
    }

    public func addPairedDevice(_ device: PairedApprovalDevice, confirmationCode: String? = nil) async throws {
        try await persist(deviceChange: .add(device), reason: confirmationCode.map { "pair \(device.name) with Agent Keyring, code \($0)" }
            ?? "pair your iPhone with Agent Keyring")
    }

    public func removePairedDevice(publicKey: Data) async throws {
        try await persist(deviceChange: .remove(publicKey), reason: "remove your paired iPhone from Agent Keyring")
    }

    public func save(_ snapshot: AccessRulesConfirmationSnapshot, reason: String) async throws {
        try await persist(policies: snapshot.policies, confirming: true, reason: reason)
    }

    private func persist(policies: [UUID: CredentialAccessPolicy]? = nil, confirming: Bool = false,
        deviceChange: PairedDeviceChange? = nil, reason: String) async throws {
        let contents: FileContents?
        do { contents = try loadVerifiedContents() }
        catch {
            guard confirming else { throw error }
            contents = nil
        }
        // Snapshots contain only policies. Device keys always come from the store verified
        // here, so a stale confirmation cannot restore a removed key or bless an injected one.
        var devices = contents?.devices ?? []
        switch deviceChange {
        case .add(let device):
            guard !devices.contains(where: { $0.publicKey == device.publicKey }) else {
                throw PairedDeviceStoreError.alreadyPaired
            }
            _ = try P256.Signing.PublicKey(x963Representation: device.publicKey)
            devices.append(device)
        case .remove(let publicKey):
            guard devices.contains(where: { $0.publicKey == publicKey }) else {
                throw PairedDeviceStoreError.notPaired
            }
            devices.removeAll { $0.publicKey == publicKey }
        case nil: break
        }
        let pendingBlocksFile = PendingIPhoneBlocks(rulesFileURL: fileURL)
        let pendingBlocks = try pendingBlocksFile.load()
        var savedPolicies = policies ?? contents?.policies ?? [:]
        if policies == nil {
            for id in pendingBlocks { savedPolicies[id] = .block }
        }
        let bytes = try Self.encodedContents(savedPolicies, devices: devices)
        let signingReason = confirming && (try? snapshotForConfirmation().requiresPhonePairingAgain) == true
            ? reason + ". Your previously paired iPhone must be paired again." : reason
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
        let context = LAContext()
        defer { context.invalidate() }
        try await authorizeSave?(context, signingReason)
        let signature = try await signer.sign(bytes, reason: signingReason, context: context)
        try await commitSave?(savedPolicies, CredentialLeaseStore.SavedRules(bytes: bytes, signature: signature), context)
        do {
            if fileManager.fileExists(atPath: signatureURL.path) { try validateOwnedRegularFile(signatureURL) }
            try bytes.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            try signature.write(to: signatureURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: signatureURL.path)
            try pendingBlocksFile.save(try pendingBlocksFile.load().subtracting(pendingBlocks))
        } catch {
            // Once the authority transaction commits, these files are only an
            // upgrade compatibility copy. Their failure cannot undo the rules.
            guard commitSave != nil else { throw error }
            accessRulesStoreLogger.error("Could not refresh the compatibility copy of the saved rules: \(error.localizedDescription, privacy: .public)")
        }
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
