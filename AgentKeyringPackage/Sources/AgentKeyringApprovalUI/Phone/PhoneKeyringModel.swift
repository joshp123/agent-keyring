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

    public init(askPhoneAfter: Duration, notificationsAllowed: Bool, keyFingerprint: String) {
        self.askPhoneAfter = askPhoneAfter
        self.notificationsAllowed = notificationsAllowed
        self.keyFingerprint = keyFingerprint
    }
}

/// Everything the iPhone app needs from the outside world.
@MainActor
public protocol PhoneKeyringBackend: AnyObject {
    /// Asks for Face ID, signs the answer and sends it. Returns the new state.
    func approve(requestID: String) async throws -> AccessRequestState
    func deny(requestID: String, reply: String?) async throws -> AccessRequestState
    func endAccess(requestID: String) async throws -> AccessRequestState
    /// Opens Apple Passwords on its export screen.
    func openPasswordsForImport()
    func setAskPhoneAfter(_ delay: Duration) async throws
    /// Live transcript of Josh speaking, until the stream is cancelled.
    func dictation() -> AsyncStream<String>
}

@MainActor
@Observable
public final class PhoneKeyringModel {
    public private(set) var requests: [AccessRequest]
    public private(set) var passwords: PasswordsOnPhone
    public private(set) var connection: ServiceConnection
    public private(set) var settings: PhoneSettings
    /// The request on screen. Set when Josh taps a notification.
    public var presentedRequestID: String?
    public var isShowingSettings = false
    public var replyDraft = ""
    public var isReplying = false
    public private(set) var isListening = false
    public private(set) var failure: String?

    private let backend: any PhoneKeyringBackend
    private var dictationTask: Task<Void, Never>?

    public init(
        backend: any PhoneKeyringBackend,
        requests: [AccessRequest],
        passwords: PasswordsOnPhone,
        connection: ServiceConnection,
        settings: PhoneSettings
    ) {
        self.backend = backend
        self.requests = requests
        self.passwords = passwords
        self.connection = connection
        self.settings = settings
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
        stopDictation()
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

    public func toggleDictation() {
        if isListening { stopDictation(); return }
        isListening = true
        let start = replyDraft.isEmpty ? "" : replyDraft + " "
        let stream = backend.dictation()
        dictationTask = Task { [weak self] in
            for await transcript in stream {
                self?.replyDraft = start + transcript
            }
            self?.isListening = false
        }
    }

    public func stopDictation() {
        dictationTask?.cancel()
        dictationTask = nil
        isListening = false
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
