import AgentKeyringApprovalUI
import AgentKeyringCredentialImport
import AgentKeyringPhoneVault
import AgentKeyringProtocol
import AgentKeyringRelaySupport
import CryptoKit
import Foundation
import LocalAuthentication
import OSLog

@MainActor
public protocol PhoneApproverKeys {
    func signingPublicKey() throws -> Data
    func authorize(_ context: LAContext, reason: String) async throws
    func sharedSecret(with publicKey: P256.KeyAgreement.PublicKey, context: LAContext) throws -> SharedSecret
    func sign(_ bytes: Data, context: LAContext) throws -> Data
}

struct PhonePendingPair: Codable {
    let endpoint: RelayEndpoint
    let relaySPKI: Data
    let previousKeySet: Data
    let transcript: Data
}

struct PhoneSavedRequest: Codable {
    let record: Data
    var lease: Data
    let metadata: PhoneVaultItemMetadata
    let machine: Data
    var decision: Data?
    var acknowledged = false
}

struct PhoneApproverState: Codable {
    var version = 1
    var endpoint: RelayEndpoint?
    var relaySPKI: Data?
    var pendingPair: PhonePendingPair?
    var pairingWanted = false
    var keySet: Data?
    var roster: Data?
    var requests: [String: PhoneSavedRequest] = [:]
    var outbox: [Data] = []
    var remoteLeases: [String: Data] = [:]
    var askPhoneAfter: UInt32 = 120
}

@MainActor
public final class PhoneRelayApprover {
    let directory: URL
    public let vault: PhoneVault
    let keys: any PhoneApproverKeys
    let identityProvider: @MainActor () throws -> RelayTLSIdentity
    var state = PhoneApproverState()
    var loaded = false
    var workTask: Task<Void, Never>?
    var retryTask: Task<Void, Never>?
    var pairingAttempt = UUID()
    var pairingStartTask: Task<Void, Never>?
    var pairTask: Task<Void, Never>?
    var pairConnection: RelayConnection?
    var authorityTask: Task<Void, Error>?
    var flushing = false
    var authorizing = false
    var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    public internal(set) var pairing = PhonePairingState.notPaired
    public internal(set) var connection = ServiceConnection.notPaired
    public internal(set) var lastFailure: String?
    var connectionFailedAt: Date?
    let logger = Logger(subsystem: "com.joshpalmer.AgentKeyring.Phone", category: "Approver")

    public init(directory: URL, vault: PhoneVault, keys: any PhoneApproverKeys,
                identity: @escaping @MainActor () throws -> RelayTLSIdentity) {
        self.directory = directory; self.vault = vault; self.keys = keys; self.identityProvider = identity
    }

    public func load() throws {
        guard !loaded else { return }
        let url = directory.appending(path: "state.plist")
        if FileManager.default.fileExists(atPath: url.path) {
            state = try PropertyListDecoder().decode(PhoneApproverState.self, from: Data(contentsOf: url))
            guard state.version == 1 else { throw RelayFailure(.unavailable, "This phone state needs a newer Agent Keyring.") }
        }
        loaded = true
        if state.keySet != nil { pairing = .paired }

        publish()
    }

    func commit(_ next: PhoneApproverState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var url = directory; try url.setResourceValues(values)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        try encoder.encode(next).write(to: directory.appending(path: "state.plist"), options: [.atomic, .completeFileProtection])
        #else
        try encoder.encode(next).write(to: directory.appending(path: "state.plist"), options: .atomic)
        #endif
        state = next
        publish()
    }

    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation; continuation.yield(())
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.observers.removeValue(forKey: id) } }
        }
    }
    func publish() { for observer in observers.values { observer.yield(()) } }
    func address(_ endpoint: RelayEndpoint) -> String { "\(endpoint.host):\(endpoint.port)" }
    static var now: Int64 { Int64(Date().timeIntervalSince1970) }

    func transport() throws -> RelayTransport {
        guard let endpoint = state.endpoint, let pin = state.relaySPKI, state.keySet != nil else {
            throw RelayFailure(.permissionDenied, "Pair this iPhone with your Mac first.")
        }
        return RelayTransport(endpoint: endpoint, identity: try identityProvider(), pin: pin)
    }

    func fail(_ error: Error, stage: String) {
        let diagnostic = error as NSError
        logger.error("\(stage, privacy: .public) failed [\(diagnostic.domain, privacy: .public):\(diagnostic.code, privacy: .public)]")
        if let failure = error as? RelayFailure { logger.error("Relay error code=\(failure.code.rawValue, privacy: .public)") }
        lastFailure = (error as? RelayFailure)?.message ?? "Agent Keyring couldn't complete the connection."
        publish()
    }

    public var askPhoneAfter: Duration { .seconds(state.askPhoneAfter) }
    public var keyFingerprint: String {
        guard state.keySet != nil || state.pendingPair != nil else { return "Not set up" }
        return (try? keys.signingPublicKey()).map { RelayCrypto.fingerprint($0) } ?? "Unavailable"
    }
}
