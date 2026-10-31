import AgentKeyringApprovalUI
import AgentKeyringPhoneApprover
import AgentKeyringRelaySupport
import Foundation
import OSLog
import UIKit
import UserNotifications

private let phoneLogger = Logger(subsystem: "com.joshpalmer.AgentKeyring.Phone", category: "App")

@MainActor
final class PhoneImportBackend: PhoneKeyringBackend {
    private let approver: PhoneRelayApprover
    private var approverUpdates: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<PhoneKeyringSnapshot>.Continuation] = [:]
    private var notificationTask: Task<Void, Never>?
    private var pushToken: Data?
    private var registeredPushToken: Data?

    private(set) var snapshot = PhoneKeyringSnapshot(
        requests: [], passwords: .notImported, connection: .notPaired,
        settings: PhoneSettings(askPhoneAfter: nil, notifications: .notSetUp, keyFingerprint: "Not set up")
    ) {
        didSet { for continuation in subscribers.values { continuation.yield(snapshot) } }
    }

    init() {
        approver = PhoneRelayApprover(directory: URL.applicationSupportDirectory.appending(path: "PhoneApprover", directoryHint: .isDirectory),
                                      keys: PhoneEnclaveKeys(),
                                      identity: { try RelayTLSIdentity.loadOrCreate(service: "com.joshpalmer.AgentKeyring.Phone.relay-tls.phone-v2") })
    }

    func updates() -> AsyncStream<PhoneKeyringSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.subscribers.removeValue(forKey: id) }
            }
        }
    }

    func openPasswordsForImport() {
        snapshot.passwords = .importFailed("Password import is not available in this release. This iPhone approves requests using the passwords kept on your Mac.")
    }

    func start() {
        if approverUpdates == nil {
            approverUpdates = Task { [weak self] in
                guard let stream = self?.approver.changes() else { return }
                for await _ in stream { self?.refreshApproverSnapshot() }
            }
        }
        approver.reconnect()
        refreshNotifications()
    }

    func stop() {
        approver.stop()
    }

    private func refreshApproverSnapshot() {
        do {
            snapshot.requests = try approver.requests()
            snapshot.connection = approver.connection
            let wasPaired = snapshot.pairing == .paired
            snapshot.pairing = approver.pairing
            snapshot.settings.keyFingerprint = approver.keyFingerprint
            snapshot.settings.rulesUpdatedAt = approver.rulesUpdatedAt
            if !wasPaired && snapshot.pairing == .paired { refreshNotifications() }
        } catch { logFailure(error, stage: "Read approver state") }
    }

    func beginPairing(endpoint: PhoneRelayEndpoint) async throws {
        try await approver.beginPairing(endpoint: RelayEndpoint(host: endpoint.host, port: endpoint.port))
    }
    func cancelPairing() { approver.cancelPairing() }
    func approve(requestID: String) async throws -> AccessRequestState { try await approver.approve(requestID) }
    func deny(requestID: String, reply: String?) async throws -> AccessRequestState { try await approver.deny(requestID, reply: reply) }
    func endAccess(requestID: String) async throws -> AccessRequestState {
        try await approver.endAccess(requestID)
    }
    func allowAskingAgain(requestID: String) async throws -> AccessRequestState { try await approver.clearDenial(requestID) }

    func receivedPushToken(_ token: Data) {
        pushToken = token
        refreshNotifications()
    }

    func pushRegistrationFailed(_ error: Error) {
        logFailure(error, stage: "Apple notification registration")
    }

    private func refreshNotifications() {
        guard snapshot.pairing == .paired, notificationTask == nil else { return }
        notificationTask = Task { [weak self] in
            guard let self else { return }
            defer { notificationTask = nil }
            let center = UNUserNotificationCenter.current()
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                do { _ = try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
                catch { logFailure(error, stage: "Notification permission") }
                settings = await center.notificationSettings()
            }
            let allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            for notification in await center.deliveredNotifications() { PhonePushReceipt.record(notification) }
            snapshot.settings.notifications = allowed && PhonePushReceipt.received ? .on : .notSetUp
            guard allowed else { return }
            if pushToken == nil { UIApplication.shared.registerForRemoteNotifications(); return }
            guard let token = pushToken, registeredPushToken != token else { return }
            guard let environment = Bundle.main.object(forInfoDictionaryKey: "AgentKeyringAPNSEnvironment") as? String,
                  ["development", "production"].contains(environment) else {
                phoneLogger.error("The build has no matching notification environment")
                return
            }
            do {
                try await approver.registerPush(token: token, production: environment == "production")
                registeredPushToken = token
            } catch { logFailure(error, stage: "Relay notification registration") }
        }
    }

    private func logFailure(_ error: any Error, stage: String) {
        let diagnostic = error as NSError
        phoneLogger.error("\(stage, privacy: .public) failed [\(diagnostic.domain, privacy: .public):\(diagnostic.code, privacy: .public)]")
    }
}

/// Registration is not delivery. Only a remote notification observed by iOS counts.
enum PhonePushReceipt {
    private static let receivedKey = "receivedRelayPush"
    static var received: Bool { UserDefaults.standard.bool(forKey: receivedKey) }

    static func record(_ notification: UNNotification) {
        guard notification.request.trigger is UNPushNotificationTrigger,
              notification.request.content.userInfo["ck"] == nil else { return }
        UserDefaults.standard.set(true, forKey: receivedKey)
    }
}
