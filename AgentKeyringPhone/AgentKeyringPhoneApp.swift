import Observation
import Security
import SwiftUI
import UIKit
import UserNotifications

@main
struct AgentKeyringPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                Button("Send test request") {
                    Task { await SpikeLog.shared.scheduleRequest() }
                }
                Text(SpikeLog.shared.status)
                ScrollView {
                    Text(SpikeLog.shared.contents)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .task { await SpikeLog.shared.prepare() }
        }
    }
}

final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.setNotificationCategories([
            UNNotificationCategory(
                identifier: "SIGNING_SPIKE",
                actions: [
                    UNNotificationAction(identifier: "APPROVE", title: "Approve", options: [.authenticationRequired]),
                    UNNotificationAction(identifier: "DENY", title: "Deny", options: [])
                ],
                intentIdentifiers: [],
                options: []
            )
        ])
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let handlerStarted = DispatchTime.now().uptimeNanoseconds
        Task { @MainActor in
            SpikeLog.shared.handle(action: response.actionIdentifier, handlerStarted: handlerStarted)
            completionHandler()
        }
    }
}

@MainActor
@Observable
final class SpikeLog {
    static let shared = SpikeLog()
    var contents = ""
    var status = "Preparing key and notifications…"
    private var prepared = false
    private let logURL = URL.documentsDirectory.appending(path: "signing-spike.log")

    private init() {
        do {
            if FileManager.default.fileExists(atPath: logURL.path) {
                contents = try String(contentsOf: logURL, encoding: .utf8)
            }
        } catch {
            status = "Cannot read log: \(error)"
        }
    }

    func prepare() async {
        guard !prepared else { return }
        prepared = true
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try EnclaveSigningKey.loadOrCreate()
            append(action: "KEY_READY", result: "success", started: started)
            let permitted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            )
            status = permitted ? "Ready. Send a request, then lock the phone." : "Notifications denied. Enable them in Settings."
        } catch {
            append(action: "SETUP", result: failure(error), started: started)
            status = "Setup failed: \(error)"
        }
    }

    func scheduleRequest() async {
        let started = DispatchTime.now().uptimeNanoseconds
        let content = UNMutableNotificationContent()
        content.title = "Agent Keyring signing test"
        content.body = "Approve signs a fixed test payload. No password is involved."
        content.categoryIdentifier = "SIGNING_SPIKE"
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 15, repeats: false)
                )
            )
            append(action: "SCHEDULE", result: "success", started: started)
            status = "Request scheduled in 15 seconds. Lock the phone now."
        } catch {
            append(action: "SCHEDULE", result: failure(error), started: started)
            status = "Scheduling failed: \(error)"
        }
    }

    func handle(action: String, handlerStarted: UInt64) {
        let appState = UIApplication.shared.applicationState
        var result = "success unsigned"
        if action == "APPROVE" {
            do {
                let privateKey = try EnclaveSigningKey.loadOrCreate()
                var signingError: Unmanaged<CFError>?
                let payload = Data("AgentKeyringPhone signing spike fixed payload v1".utf8)
                guard let signature = SecKeyCreateSignature(
                    privateKey, .ecdsaSignatureMessageX962SHA256, payload as CFData, &signingError
                ) else {
                    throw signingError!.takeRetainedValue() as Error
                }
                result = "success signature_bytes=\(CFDataGetLength(signature))"
            } catch {
                result = failure(error)
            }
        }
        append(action: action, result: result, started: handlerStarted, appState: appState)
    }

    private func failure(_ error: Error) -> String {
        let error = error as NSError
        return "failure domain=\(error.domain) code=\(error.code)"
    }

    private func append(
        action: String, result: String, started: UInt64,
        appState: UIApplication.State? = nil
    ) {
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let state: String
        switch appState ?? UIApplication.shared.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        let timestamp = Date().ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
        let line = "\(timestamp) action=\(action) state=\(state) \(result) milliseconds=\(String(format: "%.3f", milliseconds))\n"
        do {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try Data().write(to: logURL, options: .completeFileProtectionUntilFirstUserAuthentication)
            }
            let logHandle = try FileHandle(forWritingTo: logURL)
            defer { try? logHandle.close() }
            try logHandle.seekToEnd()
            try logHandle.write(contentsOf: Data(line.utf8))
            contents += line
        } catch {
            status = "Cannot write log: \(error)"
            contents += "LOG_WRITE_FAILED \(failure(error))\n" + line
        }
    }
}

enum EnclaveSigningKey {
    private static let tag = Data("com.joshpalmer.AgentKeyring.Phone.signing-spike.v1".utf8)

    static func loadOrCreate() throws -> SecKey {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: tag,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
            kSecReturnRef: true
        ]
        var existingKey: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &existingKey)
        if status == errSecSuccess { return existingKey as! SecKey }
        guard status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &accessError
        ) else {
            throw accessError!.takeRetainedValue() as Error
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrTokenID: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: tag,
                kSecAttrAccessControl: accessControl
            ]
        ]
        var creationError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &creationError) else {
            throw creationError!.takeRetainedValue() as Error
        }
        return key
    }
}
