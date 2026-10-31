// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Mock data for the iPhone app until release 4 wires in the real backend.
// Launch with `-designScenario <name>` to open the app in one state; the
// design screenshots in docs/design/screens come from these.

import Foundation

public enum PhoneDesignScenario: String, CaseIterable, Sendable {
    case home
    case nothingWaiting
    case request
    case requestForProgram
    case requestForAgentProcess
    case reply
    case sending
    case approved
    case denied
    case unanswered
    case inUseDetail
    case historyDetail
    case unreachable
    case importNeeded
    case importing
    case settings
    case settingsNotPaired
    case homeNotPaired
    case pairing
    case pairingConnecting
    case pairingComparing
    case pairingPaired
    case pairingFailed

    public static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Self? {
        guard let index = arguments.firstIndex(of: "-designScenario"), arguments.indices.contains(index + 1)
        else { return nil }
        return Self(rawValue: arguments[index + 1])
    }

    @MainActor
    public func makeModel(now: Date = .now) -> PhoneKeyringModel {
        let github = DesignExamples.githubSignIn(now: now)
        let history = DesignExamples.history(now: now)
        var requests = [github] + history
        var passwords = PasswordsOnPhone.imported(count: 522, at: now.addingTimeInterval(-3 * 86_400))
        var connection = ServiceConnection.connected(service: DesignExamples.macMini.name,
            lastContact: now.addingTimeInterval(-4))
        var presented: String?
        var replying = false
        var reply = ""
        var showingSettings = false
        var pairing = PhonePairingState.paired

        switch self {
        case .home, .inUseDetail, .historyDetail:
            break
        case .nothingWaiting:
            requests = history.filter { !$0.state.isInUse }
        case .request:
            presented = github.id
        case .requestForProgram:
            let program = DesignExamples.ghProgram(now: now)
            requests = [program] + history
            presented = program.id
        case .requestForAgentProcess:
            let read = DesignExamples.agentProcessRead(now: now)
            requests = [read] + history
            presented = read.id
        case .reply:
            presented = github.id
            replying = true
            reply = "Don't sign in. The invoice is already in my email, use that."
        case .sending:
            requests[0].state = .sendingAnswer(.approve)
            presented = github.id
        case .approved:
            requests[0].state = .approved(by: .iPhone, until: now.addingTimeInterval(30 * 60))
            presented = github.id
        case .denied:
            requests[0].state = .denied(by: .iPhone, reply: "Don't sign in. The invoice is already in my email, use that.",
                askAgainAfter: now.addingTimeInterval(30 * 60))
            presented = github.id
        case .unanswered:
            requests[0].state = .unanswered
            presented = github.id
        case .unreachable:
            requests = history
            connection = .unreachable(service: DesignExamples.macMini.name, since: now.addingTimeInterval(-11 * 60))
        case .importNeeded:
            requests = []
            passwords = .notImported
        case .importing:
            requests = []
            passwords = .importing(received: 318)
        case .settings:
            showingSettings = true
        case .settingsNotPaired:
            showingSettings = true
            pairing = .notPaired
        case .homeNotPaired:
            requests = history.filter { !$0.state.isInUse }
            pairing = .notPaired
        case .pairing:
            pairing = .notPaired
        case .pairingConnecting:
            pairing = .connecting
        case .pairingComparing:
            pairing = .comparing(fingerprint: DesignExamples.iPhoneEnrolment(now: now).code,
                relayAddress: "mac-mini:17443")
        case .pairingPaired:
            pairing = .paired
        case .pairingFailed:
            pairing = .failed("Couldn't reach mac-mini:17443. Check that Tailscale is on.")
        }

        let snapshot = PhoneKeyringSnapshot(
            requests: requests,
            passwords: passwords,
            connection: connection,
            settings: PhoneSettings(askPhoneAfter: .seconds(120), notificationsAllowed: true,
                keyFingerprint: "7F3A 91C2 0B4E D8A5 6C17 E902 44BB 13F0",
                rulesUpdatedAt: now.addingTimeInterval(-11 * 60)),
            pairing: pairing
        )
        let model = PhoneKeyringModel(backend: DesignPhoneBackend(snapshot: snapshot), initial: snapshot)
        model.presentedRequestID = presented
        model.isReplying = replying
        model.replyDraft = reply
        model.isShowingSettings = showingSettings
        return model
    }

    /// The pairing screens open as a sheet over the home list.
    public var opensPairing: Bool {
        switch self {
        case .pairing, .pairingConnecting, .pairingComparing, .pairingPaired, .pairingFailed: true
        default: false
        }
    }

    /// The screen this scenario opens, beyond the home list.
    public var pushedRequestID: String? {
        switch self {
        case .inUseDetail: "h-ns"
        case .historyDetail: "h-instagram"
        default: nil
        }
    }
}

/// Answers instantly and pretends every network call works.
@MainActor
final class DesignPhoneBackend: PhoneKeyringBackend {
    private let snapshot: PhoneKeyringSnapshot

    init(snapshot: PhoneKeyringSnapshot) { self.snapshot = snapshot }

    func updates() -> AsyncStream<PhoneKeyringSnapshot> {
        AsyncStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }

    func approve(requestID: String) async throws -> AccessRequestState {
        try await Task.sleep(for: .milliseconds(600))
        return .approved(by: .iPhone, until: Date.now.addingTimeInterval(RequestedAccess.longestLease))
    }

    func deny(requestID: String, reply: String?) async throws -> AccessRequestState {
        try await Task.sleep(for: .milliseconds(400))
        return .denied(by: .iPhone, reply: reply, askAgainAfter: .now.addingTimeInterval(30 * 60))
    }

    func endAccess(requestID: String) async throws -> AccessRequestState {
        .ended(at: .now)
    }

    func allowAskingAgain(requestID: String) async throws -> AccessRequestState {
        guard case let .denied(by, reply, _)? = snapshot.requests.first(where: { $0.id == requestID })?.state
        else { return .ended(at: .now) }
        return .denied(by: by, reply: reply, askAgainAfter: nil)
    }

    func openPasswordsForImport() {}

    func setAskPhoneAfter(_ delay: Duration) async throws {}

    func dictation() -> AsyncThrowingStream<String, any Error> {
        let words = "Stop. Use the invoice in my email instead.".split(separator: " ")
        return AsyncThrowingStream { continuation in
            let task = Task {
                var transcript = ""
                for word in words {
                    try? await Task.sleep(for: .milliseconds(250))
                    if Task.isCancelled { break }
                    transcript += (transcript.isEmpty ? "" : " ") + word
                    continuation.yield(transcript)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
