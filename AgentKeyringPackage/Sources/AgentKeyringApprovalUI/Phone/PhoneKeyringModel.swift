// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The iPhone app's one view model. Views read its values and call its
// methods; everything real (push, the tailnet, Face ID)
// sits behind PhoneKeyringBackend, so it can arrive without touching a view.

import Foundation
import Observation

public enum ServiceConnection: Hashable, Sendable {
    case connected(service: String, lastContact: Date)
    case unreachable(service: String, since: Date)
    case notPaired
}

/// Whether a waiting request can reach Josh without him opening the app.
public enum PhoneNotifications: Hashable, Sendable {
    /// Push isn't working yet: no push key, or not registered with the relay.
    case notSetUp
    /// iOS notifications are turned off for Agent Keyring.
    case off
    /// Registered with the relay; a waiting request notifies this iPhone.
    case on
}

public struct PhoneSettings: Hashable, Sendable {
    /// The real permission and registration result, never a placeholder.
    public var notifications: PhoneNotifications
    public var keyFingerprint: String
    public var rulesUpdatedAt: Date?

    public init(notifications: PhoneNotifications, keyFingerprint: String, rulesUpdatedAt: Date? = nil) {
        self.notifications = notifications
        self.keyFingerprint = keyFingerprint
        self.rulesUpdatedAt = rulesUpdatedAt
    }
}

/// Everything the phone shows that comes from outside it, at one moment.
public struct PhoneKeyringSnapshot: Hashable, Sendable {
    /// Waiting, in use and recent requests, in any order.
    public var requests: [AccessRequest]
    public var connection: ServiceConnection
    public var settings: PhoneSettings
    public var pairing: PhonePairingState

    public init(requests: [AccessRequest], connection: ServiceConnection,
        settings: PhoneSettings, pairing: PhonePairingState = .notPaired) {
        self.requests = requests
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
}

@MainActor
@Observable
public final class PhoneKeyringModel {
    public private(set) var requests: [AccessRequest]
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
        connection = snapshot.connection
        settings = snapshot.settings
        pairing = snapshot.pairing
        settlePendingActions()
    }

    /// End and Let it ask again stay "sending" until the Mac's own report
    /// shows the change (RFC 0006); the phone never assumes it happened.
    public private(set) var ending = Set<String>()
    public private(set) var askingAgain = Set<String>()

    private func settlePendingActions() {
        ending = ending.filter { request(id: $0)?.state.isInUse == true }
        askingAgain = askingAgain.filter { request(id: $0)?.state.isHoldingOffNewRequests(now: .now) == true }
    }

    public var waiting: [AccessRequest] { requests.filter(\.state.isWaitingForYou) }
    /// Answered here, not yet committed by the Mac.
    public var waitingForMac: [AccessRequest] { requests.filter(\.state.isWaitingForMac) }
    public var inUse: [AccessRequest] { requests.filter(\.state.isInUse) }
    public var finished: [AccessRequest] {
        requests.filter { !$0.state.isWaitingForYou && !$0.state.isWaitingForMac && !$0.state.isInUse }
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
        ending.insert(id)
        do { update(id, to: try await backend.endAccess(requestID: id)) }
        catch {
            ending.remove(id)
            failure = "Couldn't end it. Agent Keyring will end it at the deadline anyway."
        }
        settlePendingActions()
    }

    public func allowAskingAgain(_ id: String) async {
        askingAgain.insert(id)
        do { update(id, to: try await backend.allowAskingAgain(requestID: id)) }
        catch {
            askingAgain.remove(id)
            failure = "Couldn't change that. Agent Keyring isn't reachable."
        }
        settlePendingActions()
    }

    public func beginPairing(endpoint: PhoneRelayEndpoint) async {
        do { try await backend.beginPairing(endpoint: endpoint) }
        catch { failure = "Couldn’t start pairing. Check the relay address and Tailscale." }
    }

    public func cancelPairing() { backend.cancelPairing() }

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
