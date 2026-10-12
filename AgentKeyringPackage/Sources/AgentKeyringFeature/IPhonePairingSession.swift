import AgentKeyringApprovalCore
import CryptoKit
import Foundation

/// One session can consume only one CloudKit response. The secret stays in memory.
@MainActor
public final class IPhonePairingSession {
    public private(set) var code: PairingCode?
    private let pairingID: UUID
    private let database: any ApprovalCloudDatabase
    private let now: () -> Date
    private var isCancelled = false
    private var requestForConfirmation: PairingRequest?
    private let expiresAt: Date

    public init(database: any ApprovalCloudDatabase, now: @escaping () -> Date = Date.init) throws {
        let code = try PairingCode(now: now())
        self.code = code
        pairingID = code.id
        expiresAt = code.expiresAt
        self.database = database
        self.now = now
    }

    public func poll() async throws -> PairingRequest? {
        guard let code else { throw PairingFailure.alreadyUsed }
        guard now() < expiresAt else {
            try await cancel()
            throw PairingFailure.expired
        }
        guard let record = try await database.fetch(PairingCloudRecords.recordID(pairingID)) else { return nil }
        // Consume before any await, including deletion. A rejected record burns this QR too.
        guard self.code != nil else {
            try await database.delete(record.recordID)
            throw PairingFailure.alreadyUsed
        }
        self.code = nil
        let result = Result { () throws -> PairingRequest in
            let request = try PairingCloudRecords.request(from: record, pairingID: pairingID)
            try request.verify(code: code, now: now())
            return request
        }
        try await database.delete(record.recordID)
        guard !isCancelled else { throw PairingFailure.alreadyUsed }
        let request = try result.get()
        requestForConfirmation = request
        return request
    }

    public func confirm(in store: CredentialAccessPolicyStore, confirmationCode: String) async throws {
        guard let request = requestForConfirmation else { throw PairingFailure.alreadyUsed }
        guard confirmationCode == PairingRequest.confirmationCode(publicKey: request.publicKey) else {
            throw PairingFailure.confirmationCodeMismatch
        }
        requestForConfirmation = nil
        guard now() < expiresAt else { throw PairingFailure.expired }
        let key = try P256.Signing.PublicKey(x963Representation: request.publicKey)
        try await store.addPairedDevice(PairedApprovalDevice(publicKey: key, name: request.deviceName, pairedAt: now()), confirmationCode: confirmationCode)
    }

    public func cancel() async throws {
        isCancelled = true
        code = nil
        requestForConfirmation = nil
        try await Task { @MainActor in
            try await database.delete(PairingCloudRecords.recordID(pairingID))
        }.value
    }
}
