// Written by AI on 2026.11.18 by model claude opus 5.5; edited on 2026.11.27 by model claude opus 5.5.

#if os(macOS)
import AgentKeyringSealing
import Foundation
import Security

/// Where the Mac keeps its lists and its push key: the app's own keychain,
/// where no other program running as Josh can read or change them; files for
/// the test peer; memory in tests. The lists are small
/// (signed documents, push addresses, mailboxes and the iCloud checkpoint);
/// the sealed copies stay in MacVaultFileStore.
public struct MacKeychainStateStore {
    /// Nil when nothing is saved under the name; throws when what is saved could not be read.
    let load: @MainActor (String) throws -> Data?
    let write: @MainActor (Data, String) throws -> Void

    /// What is saved under the name, for a test to look at: nil when there is nothing, or it could not be read.
    @MainActor func read(_ name: String) -> Data? { try? load(name) }

    static let service = (Bundle.main.bundleIdentifier ?? "com.agentkeyring") + ".lists.v3"

    @MainActor public static func app() -> MacKeychainStateStore {
        let keychain = DeviceKeychainStore(service: service, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        return MacKeychainStateStore(load: { try keychain.readKeychainItem($0) }, write: { try keychain.writeKeychainItem($0, account: $1) })
    }

    #if DEBUG
    @MainActor package static func files(in folder: URL) -> MacKeychainStateStore {
        MacKeychainStateStore(load: { account in
            let file = folder.appending(path: account)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try Data(contentsOf: file)
        }, write: { bytes, account in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bytes.write(to: folder.appending(path: account), options: .atomic)
        })
    }
    #endif

    @MainActor public static func memory() -> MacKeychainStateStore {
        final class InMemoryKeychainItems: @unchecked Sendable { var items: [String: Data] = [:] } // Touched only on the main actor.
        let memoryItems = InMemoryKeychainItems()
        return MacKeychainStateStore(load: { memoryItems.items[$0] }, write: { memoryItems.items[$1] = $0 })
    }
}

/// Wakes everything waiting on a change: a join, a practice request's progress.
@MainActor
final class MacWakeSignal {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func fire() {
        let all = waiters
        waiters = [:]
        for waiter in all.values { waiter.resume() }
    }

    /// Returns on the next change, or at `deadline`.
    func wait(until deadline: ContinuousClock.Instant) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(until: deadline)
                    self?.resume(id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(id) }
        }
    }

    private func resume(_ id: UUID) { waiters.removeValue(forKey: id)?.resume() }
}
#endif
