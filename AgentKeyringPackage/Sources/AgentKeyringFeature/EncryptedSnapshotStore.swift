import CryptoKit
import Foundation
import OSLog
import Security

public protocol MirrorVaultKeyProviding: Sendable {
    func loadOrCreateKey() throws -> SymmetricKey
}

public struct KeychainVaultKeyProvider: MirrorVaultKeyProviding {
    private let service: String
    private let account: String

    public init(
        service: String = "\(Bundle.main.bundleIdentifier ?? "com.example.AgentKeyring").vault",
        account: String = "snapshot-key"
    ) {
        self.service = service
        self.account = account
    }

    public func loadOrCreateKey() throws -> SymmetricKey {
        if let existingKey = try readKey() {
            return SymmetricKey(data: existingKey)
        }

        let keyData = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: keyData,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem, let existingKey = try readKey() {
            return SymmetricKey(data: existingKey)
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        return SymmetricKey(data: keyData)
    }

    private func readKey() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return data
    }
}

public struct StaticVaultKeyProvider: MirrorVaultKeyProviding {
    private let keyData: Data

    public init(keyData: Data) {
        self.keyData = keyData
    }

    public func loadOrCreateKey() throws -> SymmetricKey {
        SymmetricKey(data: keyData)
    }
}

public struct KeychainError: Error, Equatable, LocalizedError {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        "The mirror encryption key could not be accessed (status \(status))."
    }
}

public actor EncryptedSnapshotStore {
    private let directoryURL: URL
    private let keyProvider: any MirrorVaultKeyProviding
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        directoryURL: URL = EncryptedSnapshotStore.defaultDirectoryURL(),
        keyProvider: any MirrorVaultKeyProviding = KeychainVaultKeyProvider(),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.keyProvider = keyProvider
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
    }

    public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
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
            .appendingPathComponent("vault", isDirectory: true)
    }

    public func loadCurrent() throws -> MirrorGeneration? {
        guard let generationID = try currentGenerationID() else { return nil }
        return try load(generationID: generationID)
    }

    public func loadCurrentMetadata() throws -> MirrorMetadata? {
        guard let generationID = try currentGenerationID() else { return nil }
        let metadataURL = metadataURL(for: generationID)
        if !fileManager.fileExists(atPath: metadataURL.path) {
            let generation = try load(generationID: generationID)
            try saveMetadata(for: generation)
            Logger(subsystem: "com.agentkeyring.app", category: "MirrorStorage")
                .info("Rebuilt the missing metadata index for the current mirror")
        }
        return try decoder.decode(MirrorMetadata.self, from: decryptedData(at: metadataURL))
    }

    private func currentGenerationID() throws -> UUID? {
        try prepareDirectory()
        let pointerURL = directoryURL.appendingPathComponent("current", isDirectory: false)
        guard fileManager.fileExists(atPath: pointerURL.path) else { return nil }
        let pointerData = try Data(contentsOf: pointerURL)
        guard let pointer = String(data: pointerData, encoding: .utf8),
            let generationID = UUID(uuidString: pointer.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw MirrorError.invalidCurrentPointer
        }
        return generationID
    }

    public func load(generationID: UUID) throws -> MirrorGeneration {
        try prepareDirectory()
        return try decoder.decode(MirrorGeneration.self,
            from: decryptedData(at: generationURL(for: generationID)))
    }

    private func decryptedData(at encryptedURL: URL) throws -> Data {
        guard fileManager.fileExists(atPath: encryptedURL.path) else {
            throw MirrorError.missingEncryptedPayload
        }
        let encryptedData = try Data(contentsOf: encryptedURL)
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        return try AES.GCM.open(sealedBox, using: keyProvider.loadOrCreateKey())
    }

    public func save(_ generation: MirrorGeneration) throws {
        try prepareDirectory()
        let cleartext = try encoder.encode(generation)
        let sealedBox = try AES.GCM.seal(
            cleartext,
            using: keyProvider.loadOrCreateKey()
        )
        guard let combined = sealedBox.combined else {
            throw MirrorError.missingEncryptedPayload
        }

        let encryptedURL = generationURL(for: generation.id)
        if !fileManager.fileExists(atPath: encryptedURL.path) {
            try combined.write(to: encryptedURL, options: [.atomic])
        }
        try saveMetadata(for: generation)

        let pointerURL = directoryURL.appendingPathComponent("current", isDirectory: false)
        try Data(generation.id.uuidString.utf8).write(to: pointerURL, options: [.atomic])
        let generationsURL = directoryURL.appendingPathComponent("generations", isDirectory: true)
        for fileURL in try fileManager.contentsOfDirectory(at: generationsURL, includingPropertiesForKeys: nil) {
            guard ["mirror", "metadata"].contains(fileURL.pathExtension),
                let storedID = UUID(uuidString: fileURL.deletingPathExtension().lastPathComponent),
                storedID != generation.id else { continue }
            try fileManager.removeItem(at: fileURL)
        }
    }

    public func generationFileURL(for generationID: UUID) -> URL {
        generationURL(for: generationID)
    }

    private func saveMetadata(for generation: MirrorGeneration) throws {
        let metadata = try encoder.encode(generation.metadata)
        let metadataBox = try AES.GCM.seal(metadata, using: keyProvider.loadOrCreateKey())
        guard let metadataBytes = metadataBox.combined else { throw MirrorError.missingEncryptedPayload }
        try metadataBytes.write(to: metadataURL(for: generation.id), options: [.atomic])
    }

    private func generationURL(for generationID: UUID) -> URL {
        directoryURL
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent("\(generationID.uuidString).mirror", isDirectory: false)
    }

    private func metadataURL(for generationID: UUID) -> URL {
        directoryURL
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent("\(generationID.uuidString).metadata", isDirectory: false)
    }

    private func prepareDirectory() throws {
        let generationsURL = directoryURL.appendingPathComponent("generations", isDirectory: true)
        try fileManager.createDirectory(
            at: generationsURL,
            withIntermediateDirectories: true
        )
        var excludedDirectoryURL = directoryURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludedDirectoryURL.setResourceValues(resourceValues)
    }
}
