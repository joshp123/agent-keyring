import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

/// Only the signed app can update the data-protection Keychain checkpoint.
/// Snapshot files carry no secrets. Neither a file edit nor an older valid file
/// can change the checkpoint. Alternating slots preserve the committed state if
/// the process exits between the file write and the Keychain transaction.
@MainActor
public final class LeasePersistence {
    private let directory: URL
    private let service: String
    private var currentSlot: Int?

    public init(directory: URL = CredentialAccessPolicyStore.defaultFileURL()
        .deletingLastPathComponent().appendingPathComponent("leases"),
        checkpointService: String = "com.agentkeyring.authority-checkpoint.v1") {
        self.directory = directory
        self.service = checkpointService
    }

    public func load() throws -> Data? {
        var query = checkpointQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            guard !(0...1).contains(where: { FileManager.default.fileExists(atPath: slotURL($0).path) }) else {
                throw LeaseFailure(.unavailable, "The saved lease authority checkpoint is missing. Nothing was authorized.")
            }
            return nil
        }
        guard status == errSecSuccess, let digest = result as? Data else { throw KeychainError(status: status) }
        for slot in 0...1 {
            if let bytes = try? Data(contentsOf: slotURL(slot)), Data(SHA256.hash(data: bytes)) == digest {
                currentSlot = slot
                return bytes
            }
        }
        throw LeaseFailure(.unavailable, "The saved lease authority state does not match its checkpoint. Nothing was authorized.")
    }

    public func save(_ bytes: Data) throws {
        let slot = currentSlot == 0 ? 1 : 0
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try bytes.write(to: slotURL(slot), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: slotURL(slot).path)
        let descriptor = open(slotURL(slot).path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let directoryDescriptor = open(directory.path, O_RDONLY)
        guard directoryDescriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let digest = Data(SHA256.hash(data: bytes))
        var status = SecItemUpdate(checkpointQuery as CFDictionary, [kSecValueData as String: digest] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = checkpointQuery
            attributes[kSecValueData as String] = digest
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        currentSlot = slot
    }

    private func slotURL(_ slot: Int) -> URL { directory.appendingPathComponent("authority-\(slot).plist") }
    private var checkpointQuery: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "committed-snapshot", kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false,
         kSecUseAuthenticationContext as String: context]
    }
}
