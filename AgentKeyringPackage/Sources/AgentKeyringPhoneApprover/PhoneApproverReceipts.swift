// Written by AI on 2026.11.01 by model gpt-6.1-sol.
import AgentKeyringProtocol
import AgentKeyringRelaySupport
import Foundation

extension PhoneRelayApprover {
    func queueUpdateReceipt(kind: Agentkeyring_V1_UpdateKind, revision: UInt64, payload: Data,
                            into next: inout PhoneApproverState) throws {
        var receipt = Agentkeyring_V1_UpdateReceipt()
        receipt.domain = "agentkeyring.update-receipt.v1"
        receipt.deviceSpkiSha256 = RelayCrypto.hash(try identityProvider().publicKeySPKI)
        receipt.kind = kind; receipt.revision = revision; receipt.updateSha256 = RelayCrypto.hash(payload)
        let body = try receipt.serializedData()
        for bytes in next.outbox {
            let command = try Agentkeyring_V1_RelayWireRequest(serializedBytes: bytes)
            if case let .publishUpdateReceipt(saved) = command.request, saved.receipt == body { return }
        }
        let acknowledged = kind == .approverKeys ? next.acknowledgedKeyReceipt : next.acknowledgedConfigurationReceipt
        if let acknowledged, try Agentkeyring_V1_SignedUpdateReceipt(serializedBytes: acknowledged).receipt == body { return }
        var command = Agentkeyring_V1_RelayWireRequest()
        command.publishUpdateReceipt.receipt = body
        // Save the exact receipt body with the verified update. The outbox adds
        // and saves its TLS signature before sending, without biometric access.
        let index = try next.outbox.firstIndex { bytes in
            let saved = try Agentkeyring_V1_RelayWireRequest(serializedBytes: bytes)
            if case .publishUpdateReceipt = saved.request { return false }
            return true
        } ?? next.outbox.endIndex
        next.outbox.insert(try command.serializedData(), at: index)
    }

    func retryRetainedReceipt(kind: Agentkeyring_V1_UpdateKind, revision: UInt64, payload: Data) throws {
        let acknowledged = kind == .approverKeys ? state.acknowledgedKeyReceipt : state.acknowledgedConfigurationReceipt
        guard let acknowledged else { return }
        let signed = try Agentkeyring_V1_SignedUpdateReceipt(serializedBytes: acknowledged)
        let receipt = try Agentkeyring_V1_UpdateReceipt(serializedBytes: signed.receipt)
        guard receipt.kind == kind, receipt.revision == revision, receipt.updateSha256 == RelayCrypto.hash(payload) else { return }
        var command = Agentkeyring_V1_RelayWireRequest(); command.publishUpdateReceipt = signed
        let bytes = try command.serializedData()
        guard !state.outbox.contains(bytes) else { return }
        var next = state; next.outbox.insert(bytes, at: 0); try commit(next)
    }

    func receiveTrustUpdate(_ update: Agentkeyring_V1_TrustUpdate) throws {
        switch update.update {
        case let .approverKeys(signed):
            let candidate = try parsedKeys(signed)
            if candidate.revision < (try parsedKeys(currentKeys())).revision {
                try retryRetainedReceipt(kind: .approverKeys, revision: candidate.revision, payload: signed.keySet)
            } else { try applyApproverKeys(signed) }
        case let .configuration(signed):
            let candidate = try Agentkeyring_V1_Configuration(serializedBytes: signed.configuration)
            if let current = try? configuration(), candidate.revision < current.revision {
                try retryRetainedReceipt(kind: .configuration, revision: candidate.revision, payload: signed.configuration)
            } else { try applyConfiguration(signed) }
        case nil: throw RelayFailure(.invalidArgument, "The relay sent an empty trust update.")
        }
    }

    func discardWithdrawnRequests(in next: inout PhoneApproverState) throws {
        guard let configurationBytes = next.configuration, let keyBytes = next.keySet else { return }
        let signed = try Agentkeyring_V1_SignedConfiguration(serializedBytes: configurationBytes)
        let configuration = try Agentkeyring_V1_Configuration(serializedBytes: signed.configuration)
        let set = try parsedKeys(Agentkeyring_V1_SignedApproverKeySet(serializedBytes: keyBytes))
        for (id, saved) in next.requests {
            let record = try Agentkeyring_V1_RequestRecord(serializedBytes: saved.record)
            let lease = try Agentkeyring_V1_Lease(serializedBytes: saved.lease)
            guard lease.state == .pending || (saved.hasAnswer && !saved.acknowledged) else { continue }
            let login = configuration.logins.first { $0.loginID == record.loginID }
            let trustedMac = set.keys.contains { $0.keyID == saved.sourceMacKeyID && ($0.role == .mac || ($0.role == .unspecified && $0.keyID == set.ruleOwnerKeyID)) }
            let currentMachine = saved.isLocal || configuration.machines.contains { (try? $0.serializedData()) == saved.machine }
            if !trustedMac || !currentMachine || login == nil || login?.rule == .blocked || login.map(PhoneRequestLogin.init) != saved.metadata {
                next.requests.removeValue(forKey: id)
            }
        }
        next.outbox = try next.outbox.filter { bytes in
            let command = try Agentkeyring_V1_RelayWireRequest(serializedBytes: bytes)
            let digest: Data
            switch command.request {
            case let .decide(signed): digest = try Agentkeyring_V1_DecisionStatement(serializedBytes: signed.statement).requestDigest
            case let .answerFromPhone(signed): digest = try Agentkeyring_V1_PhoneDecision(serializedBytes: signed.decision).requestDigest
            default: return true
            }
            return next.requests[RelayCrypto.hex(digest)] != nil
        }
    }
}
