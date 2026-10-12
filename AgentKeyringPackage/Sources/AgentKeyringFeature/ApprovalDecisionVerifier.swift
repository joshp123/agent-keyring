import CryptoKit
import Foundation
import OSLog

private let approvalDecisionLogger = Logger(subsystem: "com.agentkeyring.app", category: "ApprovalDecisions")

public protocol PairedDevicePublicKeyProviding: Sendable {
    func pairedDevicePublicKeys() async throws -> [Data]
}

public enum ApprovalDecisionRefusal: String, Error, Sendable {
    case unknownRequest
    case requestAlreadyRegistered
    case mismatchedRequest
    case expired
    case replayed
    case untrustedPairedDevices
    case unpairedDevice
    case invalidSignature
}

/// Owns the Mac's pending requests and their single-use receipts. Keep this actor for the
/// lifetime of its requests. Pending requests are never restored from the remote channel;
/// after a Mac restart, decisions for the old requests therefore fail as unknownRequest.
public actor ApprovalDecisionVerifier {
    private let pairedDevices: any PairedDevicePublicKeyProviding
    private let now: @Sendable () -> Date
    private var pendingRequests: [UUID: ApprovalRequest] = [:]
    private var usedRequestExpiries: [UUID: Date] = [:]

    public init(pairedDevices: any PairedDevicePublicKeyProviding, now: @escaping @Sendable () -> Date = Date.init) {
        self.pairedDevices = pairedDevices
        self.now = now
    }

    /// Register only a request created on the Mac, before sending it to the paired device.
    public func register(_ request: ApprovalRequest) throws {
        let now = now()
        usedRequestExpiries = usedRequestExpiries.filter { $0.value > now }
        if usedRequestExpiries[request.id] != nil { throw refusal(.replayed) }
        if pendingRequests[request.id] != nil { throw refusal(.requestAlreadyRegistered) }
        guard request.expiresAt > now else { throw refusal(.expired) }
        pendingRequests = pendingRequests.filter { $0.value.expiresAt > now }
        pendingRequests[request.id] = request
    }

    public func verify(_ decision: ApprovalDecision) async throws -> ApprovalChoice {
        // Loading may suspend this actor. Check and consume the request only after it returns,
        // so two concurrent decisions cannot both consume it, and removed keys are rechecked.
        let publicKeys: [Data]
        do { publicKeys = try await pairedDevices.pairedDevicePublicKeys() }
        catch { throw refusal(.untrustedPairedDevices) }

        if usedRequestExpiries[decision.requestID] != nil { throw refusal(.replayed) }
        guard let request = pendingRequests[decision.requestID] else { throw refusal(.unknownRequest) }
        guard decision.signedFields == request.signedFields else { throw refusal(.mismatchedRequest) }
        guard request.expiresAt > now() else { throw refusal(.expired) }
        guard publicKeys.contains(decision.devicePublicKey) else { throw refusal(.unpairedDevice) }
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: decision.devicePublicKey),
            let signature = try? P256.Signing.ECDSASignature(derRepresentation: decision.signature),
            publicKey.isValidSignature(signature, for: request.signedFields.canonicalBytes(for: decision.choice))
        else { throw refusal(.invalidSignature) }

        pendingRequests.removeValue(forKey: request.id)
        usedRequestExpiries[request.id] = request.expiresAt
        return decision.choice
    }

    private func refusal(_ reason: ApprovalDecisionRefusal) -> ApprovalDecisionRefusal {
        // Only the fixed reason is logged: no IDs, login fields, nonces, keys or signatures.
        approvalDecisionLogger.error("Approval decision refused: \(reason.rawValue, privacy: .public)")
        return reason
    }
}
