import AgentKeyringApprovalCore
import CloudKit
import Foundation
import Observation
import OSLog
import UIKit
import UserNotifications

private let phoneApprovalLogger = Logger(subsystem: "com.joshpalmer.AgentKeyring.Phone", category: "Approvals")

func logPhoneFailure(_ error: Error, operation: String) {
    if let failure = error as? PhoneApprovalFailure {
        phoneApprovalLogger.error("\(operation, privacy: .public) failed: \(failure.rawValue, privacy: .public)")
    } else {
        let error = error as NSError
        // Do not log localizedDescription or userInfo: CloudKit errors can contain records.
        phoneApprovalLogger.error("\(operation, privacy: .public) failed domain=\(error.domain, privacy: .public) code=\(error.code)")
    }
}

enum PhoneApprovalFailure: String, Error {
    case publicKeyUnavailable
    case invalidNotification
    case malformedRequest
    case expiredRequest
}

struct PhoneDecisionHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let time: Date
    let choice: ApprovalChoice
    let sent: Bool
}

@MainActor
@Observable
final class PhoneApprovalModel {
    static let shared = PhoneApprovalModel()
    private(set) var iCloudStatus = "Checking…"
    var notificationStatus = "Checking…"
    private(set) var keyFingerprint: String?
    private(set) var keyStatus = "Preparing…"
    private(set) var decisions: [PhoneDecisionHistoryEntry] = []
    private(set) var lastFailure: String?
    private(set) var pairingStatus: String?
    private var pairing = false

    private let container = CKContainer(identifier: ApprovalCloudRecords.containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }
    private var preparing = false
    private let historyURL = URL.documentsDirectory.appending(path: "approval-decisions.plist")

    private init() {
        do {
            if FileManager.default.fileExists(atPath: historyURL.path) {
                decisions = try PropertyListDecoder().decode([PhoneDecisionHistoryEntry].self,
                    from: Data(contentsOf: historyURL))
            }
        } catch {
            logPhoneFailure(error, operation: "Read decision history")
            lastFailure = "Could not read recent decisions."
        }
    }

    func prepare() async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        do {
            keyFingerprint = try EnclaveSigningKey.loadOrCreate().fingerprint
            keyStatus = "Ready"
        } catch {
            logPhoneFailure(error, operation: "Prepare signing key")
            keyFingerprint = nil
            keyStatus = "Secure Enclave key unavailable"
        }

        do {
            let permitted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            notificationStatus = permitted ? "Enabled" : "Disabled in Settings"
            if permitted { UIApplication.shared.registerForRemoteNotifications() }
            else { phoneApprovalLogger.error("Notification authorization denied") }
        } catch {
            logPhoneFailure(error, operation: "Notification authorization")
            notificationStatus = "Authorization failed"
        }

        var operation = "Check iCloud account"
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available: iCloudStatus = "Available"
            case .noAccount: iCloudStatus = "Not signed in"
            case .restricted: iCloudStatus = "Restricted"
            case .couldNotDetermine: iCloudStatus = "Could not check account"
            case .temporarilyUnavailable: iCloudStatus = "Temporarily unavailable"
            @unknown default: iCloudStatus = "Unavailable"
            }
            guard status == .available else {
                phoneApprovalLogger.error("iCloud account unavailable status=\(status.rawValue)")
                return
            }
            operation = "Prepare approval zones"
            for zone in [ApprovalCloudRecords.requestZone, ApprovalCloudRecords.decisionZone] {
                _ = try await database.save(CKRecordZone(zoneID: zone))
            }
            operation = "Save approval subscription"
            _ = try await database.save(ApprovalCloudRecords.requestSubscription())
            iCloudStatus = "Ready for requests"
        } catch {
            logPhoneFailure(error, operation: operation)
            iCloudStatus = "Approval channel unavailable"
        }
    }

    func respond(to recordID: CKRecord.ID?, choice: ApprovalChoice) async {
        var operation = "Read approval notification"
        do {
            guard let recordID else { throw PhoneApprovalFailure.invalidNotification }
            operation = "Fetch approval request"
            // Re-fetch the same record used by the service extension. Never sign notification text.
            // A full fetch is required: site and account live in encryptedValues.
            let record = try await database.record(for: recordID)
            operation = "Decode approval request"
            guard let fields = ApprovalCloudRecords.signedFields(from: record) else {
                throw PhoneApprovalFailure.malformedRequest
            }
            operation = "Check approval expiry"
            guard Date().timeIntervalSince1970 < TimeInterval(fields.expiresAt) else {
                throw PhoneApprovalFailure.expiredRequest
            }
            operation = "Sign approval decision"
            let key = try EnclaveSigningKey.loadOrCreate()
            let decision = ApprovalDecision(requestID: fields.requestID, choice: choice,
                devicePublicKey: key.publicKey, signature: try key.sign(fields.canonicalBytes(for: choice)))
            // Check again before upload if key lookup or signing crossed the deadline.
            guard Date().timeIntervalSince1970 < TimeInterval(fields.expiresAt) else {
                throw PhoneApprovalFailure.expiredRequest
            }
            operation = "Save approval decision"
            _ = try await database.save(ApprovalCloudRecords.decision(decision))
            lastFailure = nil
            appendDecision(choice, sent: true)
        } catch {
            logPhoneFailure(error, operation: operation)
            switch error as? PhoneApprovalFailure {
            case .expiredRequest: lastFailure = "The request expired. No decision was sent."
            case .malformedRequest, .invalidNotification: lastFailure = "The request could not be read. No decision was sent."
            default: lastFailure = "The decision could not be sent."
            }
            appendDecision(choice, sent: false)
        }
    }

    func pair(qrPayload: String) async {
        guard !pairing else { return }
        pairing = true
        defer { pairing = false }
        pairingStatus = "Sending pairing request…"
        do {
            let code = try PairingCode(qrPayload: qrPayload)
            let key = try EnclaveSigningKey.loadOrCreate()
            keyFingerprint = PairingRequest.fingerprint(publicKey: key.publicKey)
            let request = PairingRequest(code: code, publicKey: key.publicKey, deviceName: UIDevice.current.name)
            _ = try await database.save(CKRecordZone(zoneID: PairingCloudRecords.zone))
            guard Date() < code.expiresAt else { throw PairingFailure.expired }
            _ = try await database.save(PairingCloudRecords.record(request))
            pairingStatus = "Request sent. Finish pairing on your Mac."
        } catch {
            logPhoneFailure(error, operation: "Pair with Mac")
            pairingStatus = error as? PairingFailure == .expired
                ? "This code expired. Choose Add iPhone on your Mac and scan the new code."
                : "Pairing request could not be sent. Choose Add iPhone on your Mac and try again."
        }
    }

    private func appendDecision(_ choice: ApprovalChoice, sent: Bool) {
        decisions.insert(PhoneDecisionHistoryEntry(id: UUID(), time: Date(), choice: choice, sent: sent), at: 0)
        decisions = Array(decisions.prefix(20))
        do {
            try PropertyListEncoder().encode(decisions).write(to: historyURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            logPhoneFailure(error, operation: "Save decision history")
            lastFailure = "Could not save recent decisions."
        }
    }
}
