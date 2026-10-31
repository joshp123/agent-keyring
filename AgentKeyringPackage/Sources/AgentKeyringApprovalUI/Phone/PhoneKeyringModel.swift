// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The iPhone app's one view model. Views read its values and call its
// methods; everything real (push, the tailnet, Face ID, the vault, speech)
// sits behind PhoneKeyringBackend, so it can arrive without touching a view.

import Foundation
import Observation

public enum PasswordsOnPhone: Hashable, Sendable {
    case notImported
    case importing(received: Int)
    case imported(count: Int, at: Date)
    case importFailed(String)
}

public enum ServiceConnection: Hashable, Sendable {
    case connected(service: String, lastContact: Date)
    case unreachable(service: String, since: Date)
    case notPaired
}

public struct PhoneSettings: Hashable, Sendable {
    /// How long a request waits on the Mac before it comes to this iPhone.
    public var askPhoneAfter: Duration
    public var notificationsAllowed: Bool
    public var keyFingerprint: String
    public var rulesUpdatedAt: Date?

    public init(askPhoneAfter: Duration, notificationsAllowed: Bool, keyFingerprint: String, rulesUpdatedAt: Date? = nil) {
        self.askPhoneAfter = askPhoneAfter
        self.notificationsAllowed = notificationsAllowed
        self.keyFingerprint = keyFingerprint
        self.rulesUpdatedAt = rulesUpdatedAt
    }
}

/// Everything the phone shows that comes from outside it, at one moment.
public struct PhoneKeyringSnapshot: Hashable, Sendable {
    /// Waiting, in use and recent requests, in any order.
    public var requests: [AccessRequest]
    public var passwords: PasswordsOnPhone
    public var connection: ServiceConnection
    public var settings: PhoneSettings
    public var pairing: PhonePairingState

    public init(requests: [AccessRequest], passwords: PasswordsOnPhone, connection: ServiceConnection,
        settings: PhoneSettings, pairing: PhonePairingState = .notPaired) {
        self.requests = requests
        self.passwords = passwords
        self.connection = connection
        self.settings = settings
        self.pairing = pairing
    }
}

/// Everything the iPhone app needs from the outside world.
@MainActor
public protocol PhoneKeyringBackend: AnyObject {
    /// The current snapshot first, then one each time anything changes.
    func updates() -> AsyncStream<PhoneKeyringSnapshot>
    func beginPairing(endpoint: PhoneRelayEndpoint) async throws
    func cancelPairing()
    /// Asks for Face ID, signs the answer and sends it. Returns the new state.
    func approve(requestID: String) async throws -> AccessRequestState
    func deny(requestID: String, reply: String?) async throws -> AccessRequestState
    func endAccess(requestID: String) async throws -> AccessRequestState
    /// Clears a denial's hold-off, so this machine may ask for the login again.
    func allowAskingAgain(requestID: String) async throws -> AccessRequestState
    /// Asks iOS to allow exports to Agent Keyring; the export starts in Passwords.
    func openPasswordsForImport()
    func setAskPhoneAfter(_ delay: Duration) async throws
}

@MainActor
@Observable
public final class PhoneKeyringModel {
    public private(set) var requests: [AccessRequest]
    public private(set) var passwords: PasswordsOnPhone
    public private(set) var connection: ServiceConnection
    public private(set) var settings: PhoneSettings
    public private(set) var pairing: PhonePairingState
    /// The request on screen. Set when Josh taps a notification.
    public var presentedRequestID: String?
    public var isShowingSettings = false
    public var replyDraft = ""
    public var isReplying = false
    public private(set) var failure: String?

    private let backend: any PhoneKeyringBackend

    public init(backend: any PhoneKeyringBackend, initial: PhoneKeyringSnapshot) {
        self.backend = backend
        self.requests = initial.requests
        self.passwords = initial.passwords
        self.connection = initial.connection
        self.settings = initial.settings
        self.pairing = initial.pairing
    }

    /// Follows the backend until the view goes away. Call from `.task`.
    public func followUpdates() async {
        for await snapshot in backend.updates() {
            apply(snapshot)
        }
    }

    private func apply(_ snapshot: PhoneKeyringSnapshot) {
        // An answer on its way stays on screen until the backend reports the outcome.
        let sending = Dictionary(uniqueKeysWithValues: requests.compactMap { request in
            if case .sendingAnswer = request.state { (request.id, request.state) } else { nil }
        })
        requests = snapshot.requests.map { request in
            var request = request
            if request.state.isWaitingForYou, let state = sending[request.id] { request.state = state }
            return request
        }
        passwords = snapshot.passwords
        connection = snapshot.connection
        settings = snapshot.settings
        pairing = snapshot.pairing
    }

    public var waiting: [AccessRequest] { requests.filter(\.state.isWaitingForYou) }
    public var inUse: [AccessRequest] { requests.filter(\.state.isInUse) }
    public var finished: [AccessRequest] {
        requests.filter { !$0.state.isWaitingForYou && !$0.state.isInUse }
    }

    public func request(id: String) -> AccessRequest? {
        requests.first { $0.id == id }
    }

    public func approve(_ id: String) async {
        await answer(id, choice: .approve) { try await backend.approve(requestID: id) }
    }

    public func deny(_ id: String) async {
        let reply = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isReplying = false
        await answer(id, choice: .deny) {
            try await backend.deny(requestID: id, reply: reply.isEmpty ? nil : reply)
        }
        replyDraft = ""
    }

    public func endAccess(_ id: String) async {
        do { update(id, to: try await backend.endAccess(requestID: id)) }
        catch { failure = "Couldn't end it. Agent Keyring will end it at the deadline anyway." }
    }

    public func allowAskingAgain(_ id: String) async {
        do { update(id, to: try await backend.allowAskingAgain(requestID: id)) }
        catch { failure = "Couldn't change that. Agent Keyring isn't reachable." }
    }

    public func beginPairing(endpoint: PhoneRelayEndpoint) async {
        do { try await backend.beginPairing(endpoint: endpoint) }
        catch { failure = "Couldn’t start pairing. Check the relay address and Tailscale." }
    }

    public func cancelPairing() { backend.cancelPairing() }

    public func importPasswords() {
        backend.openPasswordsForImport()
    }

    public func setAskPhoneAfter(_ delay: Duration) async {
        let previous = settings.askPhoneAfter
        settings.askPhoneAfter = delay
        do { try await backend.setAskPhoneAfter(delay) }
        catch {
            settings.askPhoneAfter = previous
            failure = "Couldn't save that. Agent Keyring isn't reachable."
        }
    }

    public func dismissFailure() { failure = nil }

    private func answer(
        _ id: String, choice: AnswerChoice, send: () async throws -> AccessRequestState
    ) async {
        guard let previous = request(id: id)?.state else { return }
        update(id, to: .sendingAnswer(choice))
        do { update(id, to: try await send()) }
        catch {
            update(id, to: previous)
            failure = "Your answer didn't reach Agent Keyring. Try again."
        }
    }

    private func update(_ id: String, to state: AccessRequestState) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].state = state
    }
}

/// Pairing screens consume these plain values; TLS validation stays in the backend.
public struct PhoneRelayEndpoint: Hashable, Sendable {
    public var host: String
    public var port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }
}

public enum PhonePairingState: Hashable, Sendable {
    case notPaired
    case connecting
    case comparing(fingerprint: String, relayAddress: String)
    case paired
    case failed(String)
}

public extension PhoneKeyringBackend {
    func beginPairing(endpoint: PhoneRelayEndpoint) async throws { throw CocoaError(.featureUnsupported) }
    func cancelPairing() { }
}
