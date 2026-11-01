// Written by AI on 2026.11.01 by model gpt-6.1-sol.
import AgentKeyringProtocol
import CryptoKit
import Foundation
import LocalAuthentication

public struct RelayPermissionDeviceStatus: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let confirmed: Bool
    public let removedByLaterChange: Bool
}

public struct RelayPermissionWithdrawal: Identifiable, Sendable {
    public let id: String
    public let kind: Agentkeyring_V1_UpdateKind
    public let revision: UInt64
    public let label: String
    public let devices: [RelayPermissionDeviceStatus]
    public let isComplete: Bool
}

struct RelayRequiredUpdateDevice: Codable {
    var spki: Data
    var label: String
    var receipt: Data?
    var retiredBy: String?
}

struct RelaySavedWithdrawal: Codable {
    var update: Data
    var label: String
    var devices: [String: RelayRequiredUpdateDevice]
    var removedDevices: Set<String>
    var sequence: UInt64
    var completedAt: Int64?
}

extension RelayApprover {
    public func removePhone(_ keyID: String, context: LAContext = LAContext()) async throws {
        try load()
        let queuedID = "remove-phone:" + keyID
        if state.outbox.contains(where: { $0.id == queuedID }) { await flushOutbox(); return }
        guard !state.outbox.contains(where: { queued in
            guard let command = try? Agentkeyring_V1_RelayWireRequest(serializedBytes: queued.bytes) else { return false }
            if case .publishApproverKeys = command.request { return true }
            return false
        }) else {
            throw LeaseFailure(.conflict, "Wait for the previous approver change to reach the relay.")
        }
        let previous = try currentKeySet()
        let previousSet = try Agentkeyring_V1_ApproverKeySet(serializedBytes: previous.keySet)
        guard let phone = previousSet.keys.first(where: { $0.keyID == keyID && $0.role == .phone }) else { return }
        let configurationBytes = state.configuration
        try claimAuthorization(queuedID)
        defer { authorizationID = nil }
        let signer = try keys().1
        guard previousSet.ruleOwnerKeyID == RelayCrypto.keyID(signer.publicKey) else {
            throw LeaseFailure(.permissionDenied, "Only the rule owner can remove an approving phone.")
        }
        try await signer.authorize(context: context, reason: "Remove \(phone.label) from Agent Keyring. Its saved password copies cannot be erased remotely")
        try Task.checkCancellation()
        guard try currentKeySet() == previous, state.configuration == configurationBytes else {
            throw LeaseFailure(.conflict, "The allowed devices changed. Review the phone again.")
        }
        var set = previousSet
        set.revision += 1
        set.keys.removeAll { $0.keyID == keyID }
        set.pairingTranscriptSha256 = Data()
        var signed = Agentkeyring_V1_SignedApproverKeySet()
        signed.keySet = try set.serializedData()
        signed.signature = try signer.sign(signed.keySet, context: context, automatic: false)
        signed.signerKeyID = set.ruleOwnerKeyID
        var command = Agentkeyring_V1_RelayWireRequest()
        command.publishApproverKeys = signed
        var next = state
        next.keySet = try signed.serializedData()
        if !phone.encryptionPublicKey.isEmpty {
            let prefix = "login-copy:\(RelayCrypto.keyID(phone.encryptionPublicKey)):"
            next.outbox.removeAll { $0.id.hasPrefix(prefix) }
        }
        next.pendingApprovers?.removeValue(forKey: keyID)
        if next.dismissedApproverPairingIDs == nil { next.dismissedApproverPairingIDs = [] }
        next.dismissedApproverPairingIDs!.insert(keyID)
        try enqueue(command, id: queuedID, into: &next)
        try recordKeyWithdrawal(previous: previousSet, signed: signed, label: "Remove \(phone.label)", into: &next)
        try commit(next)
        await flushOutbox()
    }

    func updateTarget(_ update: Agentkeyring_V1_TrustUpdate) throws -> Agentkeyring_V1_UpdateReceiptQuery {
        var target = Agentkeyring_V1_UpdateReceiptQuery()
        switch update.update {
        case let .approverKeys(signed):
            target.kind = .approverKeys
            target.revision = try Agentkeyring_V1_ApproverKeySet(serializedBytes: signed.keySet).revision
            target.updateSha256 = RelayCrypto.hash(signed.keySet)
        case let .configuration(signed):
            target.kind = .configuration
            target.revision = try Agentkeyring_V1_Configuration(serializedBytes: signed.configuration).revision
            target.updateSha256 = RelayCrypto.hash(signed.configuration)
        case nil: throw LeaseFailure(.invalidArgument, "A permission update is missing.")
        }
        guard target.revision > 0 else { throw LeaseFailure(.invalidArgument, "A permission update needs a revision.") }
        return target
    }

    func updateID(_ target: Agentkeyring_V1_UpdateReceiptQuery) -> String {
        "\(target.kind.rawValue):\(target.revision):\(RelayCrypto.hex(target.updateSha256))"
    }

    func enforcingDevices(keys: Agentkeyring_V1_ApproverKeySet, configuration: Agentkeyring_V1_Configuration?) -> [String: RelayRequiredUpdateDevice] {
        var devices: [String: RelayRequiredUpdateDevice] = [:]
        for key in keys.keys where key.role != .macDelivery && !key.tlsPublicKey.isEmpty {
            devices[RelayCrypto.keyID(key.tlsPublicKey)] = RelayRequiredUpdateDevice(spki: key.tlsPublicKey, label: key.label)
        }
        for machine in configuration?.machines ?? [] {
            devices[RelayCrypto.keyID(machine.tlsPublicKey)] = RelayRequiredUpdateDevice(spki: machine.tlsPublicKey, label: machine.machineLabel)
        }
        return devices
    }

    func recordKeyWithdrawal(previous: Agentkeyring_V1_ApproverKeySet, signed: Agentkeyring_V1_SignedApproverKeySet,
        label: String, into next: inout RelayApproverState) throws {
        let keys = try Agentkeyring_V1_ApproverKeySet(serializedBytes: signed.keySet)
        guard previous.ruleOwnerKeyID != keys.ruleOwnerKeyID || previous.keys.contains(where: { !keys.keys.contains($0) }) else { return }
        let configuration = try currentConfiguration()
        var update = Agentkeyring_V1_TrustUpdate()
        update.approverKeys = signed
        try recordWithdrawal(update, label: label,
            before: enforcingDevices(keys: previous, configuration: configuration),
            after: enforcingDevices(keys: keys, configuration: configuration), into: &next)
    }

    func recordConfigurationWithdrawal(previous: Agentkeyring_V1_Configuration?, signed: Agentkeyring_V1_SignedConfiguration,
        into next: inout RelayApproverState) throws {
        guard let previous else { return }
        let configuration = try Agentkeyring_V1_Configuration(serializedBytes: signed.configuration)
        guard Self.configurationWithdraws(previous, configuration) else { return }
        let keys = try copyApprovers(in: next)
        var update = Agentkeyring_V1_TrustUpdate()
        update.configuration = signed
        try recordWithdrawal(update, label: "Apply changed login and machine permissions",
            before: enforcingDevices(keys: keys, configuration: previous),
            after: enforcingDevices(keys: keys, configuration: configuration), into: &next)
    }

    static func configurationWithdraws(_ old: Agentkeyring_V1_Configuration, _ next: Agentkeyring_V1_Configuration) -> Bool {
        for before in old.machines {
            guard let after = next.machines.first(where: { $0.recipientID == before.recipientID }) else { return true }
            if before.tlsPublicKey != after.tlsPublicKey || before.receiverPublicKey != after.receiverPublicKey
                || before.receiverKeyID != after.receiverKeyID || before.tailscaleNodeID != after.tailscaleNodeID
                || (before.automaticAllowed && !after.automaticAllowed) { return true }
        }
        for before in old.logins {
            guard let after = next.logins.first(where: { $0.loginID == before.loginID }) else { return true }
            if (before.rule != .blocked && after.rule == .blocked) || (before.rule == .automatic && after.rule != .automatic)
                || !Set(before.sites).isSubset(of: Set(after.sites)) { return true }
        }
        return !old.automaticKeyID.isEmpty && (old.automaticKeyID != next.automaticKeyID
            || old.automaticSigningPublicKey != next.automaticSigningPublicKey
            || old.relayEncryptionPublicKey != next.relayEncryptionPublicKey)
    }

    func recordWithdrawal(_ update: Agentkeyring_V1_TrustUpdate, label: String,
        before: [String: RelayRequiredUpdateDevice], after: [String: RelayRequiredUpdateDevice],
        into next: inout RelayApproverState) throws {
        let target = try updateTarget(update)
        let id = updateID(target)
        if next.withdrawals?[id] != nil { return }
        let identity = try keys().0
        let deviceID = RelayCrypto.keyID(identity.publicKeySPKI)
        guard after[deviceID]?.spki == identity.publicKeySPKI else {
            throw LeaseFailure(.permissionDenied, "The updated permissions must keep this Mac's authenticated identity.")
        }
        let signedReceipt = try ownReceipt(for: target)
        var devices = after
        devices[deviceID]!.receipt = try signedReceipt.serializedData()
        if next.withdrawals == nil { next.withdrawals = [:] }
        next.withdrawals![id] = RelaySavedWithdrawal(update: try update.serializedData(), label: label,
            devices: devices, removedDevices: Set(before.keys).subtracting(after.keys), sequence: (next.withdrawalSequence ?? 0) + 1)
        next.withdrawalSequence = next.withdrawals![id]!.sequence
        var command = Agentkeyring_V1_RelayWireRequest()
        command.publishUpdateReceipt = signedReceipt
        // The update and local receipt become visible only after this checkpoint;
        // the outbox sends the receipt after its signed update, never before it.
        try enqueue(command, id: "update-receipt:" + id, into: &next)
        next.finishWithdrawals(now: Self.now)
    }

    func ownReceipt(for target: Agentkeyring_V1_UpdateReceiptQuery) throws -> Agentkeyring_V1_SignedUpdateReceipt {
        let identity = try keys().0
        var receipt = Agentkeyring_V1_UpdateReceipt()
        receipt.domain = "agentkeyring.update-receipt.v1"
        receipt.deviceSpkiSha256 = RelayCrypto.hash(identity.publicKeySPKI)
        receipt.kind = target.kind
        receipt.revision = target.revision
        receipt.updateSha256 = target.updateSha256
        var signed = Agentkeyring_V1_SignedUpdateReceipt()
        signed.receipt = try receipt.serializedData()
        signed.signature = try identity.sign(signed.receipt)
        return signed
    }

    func callRelay(_ command: Agentkeyring_V1_RelayWireRequest, using client: RelayTransport? = nil) async throws -> Agentkeyring_V1_RelayWireResponse {
        try await (client ?? transport()).call(command) { [weak self] update in
            guard let self else { throw CancellationError() }
            try await self.receiveTrustUpdate(update)
        }
    }

    func receiveTrustUpdate(_ update: Agentkeyring_V1_TrustUpdate) throws {
        let target = try updateTarget(update)
        let id = updateID(target)
        if state.acknowledgedUpdateReceipts?.contains(id) == true { return }
        var known = state.withdrawals?.values.compactMap { try? Agentkeyring_V1_TrustUpdate(serializedBytes: $0.update) } ?? []
        if let bytes = state.keySet {
            var current = Agentkeyring_V1_TrustUpdate()
            current.approverKeys = try Agentkeyring_V1_SignedApproverKeySet(serializedBytes: bytes)
            known.append(current)
        }
        if let bytes = state.configuration {
            var current = Agentkeyring_V1_TrustUpdate()
            current.configuration = try Agentkeyring_V1_SignedConfiguration(serializedBytes: bytes)
            known.append(current)
        }
        // This Mac is the rule owner: the relay can echo its saved publications,
        // never supply replacement rules for it to apply or acknowledge.
        guard try known.contains(where: { try updateTarget($0) == target }) else {
            let latest = try known.map(updateTarget).filter { $0.kind == target.kind }.map(\.revision).max() ?? 0
            if target.revision < latest { return }
            throw LeaseFailure(.permissionDenied, "The relay sent a permission change this Mac did not save.")
        }
        let queuedID = "update-receipt:" + id
        if state.outbox.contains(where: { $0.id == queuedID }) { return }
        var command = Agentkeyring_V1_RelayWireRequest()
        command.publishUpdateReceipt = try ownReceipt(for: target)
        var next = state
        try enqueue(command, id: queuedID, into: &next)
        try commit(next)
    }

    func collectUpdateReceipts() async throws {
        for (id, saved) in state.withdrawals ?? [:] where saved.completedAt == nil {
            let target = try updateTarget(Agentkeyring_V1_TrustUpdate(serializedBytes: saved.update))
            var command = Agentkeyring_V1_RelayWireRequest()
            command.getUpdateReceipts = target
            let response = try await callRelay(command)
            guard case let .updateReceipts(receipts) = response.response else {
                throw LeaseFailure(.unavailable, "The relay did not return the devices' permission confirmations.")
            }
            var next = state
            guard var current = next.withdrawals?[id] else { continue }
            var changed = false
            for signed in receipts.receipts {
                let receipt = try Agentkeyring_V1_UpdateReceipt(serializedBytes: signed.receipt)
                let deviceID = RelayCrypto.hex(receipt.deviceSpkiSha256)
                guard var device = current.devices[deviceID] else { continue }
                guard receipt.domain == "agentkeyring.update-receipt.v1", receipt.kind == target.kind,
                    receipt.revision == target.revision, receipt.updateSha256 == target.updateSha256,
                    receipt.deviceSpkiSha256 == RelayCrypto.hash(device.spki),
                    try P256.Signing.PublicKey(derRepresentation: device.spki).isValidSignature(
                        P256.Signing.ECDSASignature(derRepresentation: signed.signature), for: signed.receipt) else {
                    throw LeaseFailure(.permissionDenied, "A device's confirmation does not authenticate this exact permission change.")
                }
                if device.receipt == nil {
                    device.receipt = try signed.serializedData()
                    current.devices[deviceID] = device
                    changed = true
                }
            }
            if changed {
                next.withdrawals![id] = current
                next.finishWithdrawals(now: Self.now)
                try commit(next)
            }
        }
    }

    var displayedWithdrawals: [RelayPermissionWithdrawal] {
        (state.withdrawals ?? [:]).compactMap { id, saved in
            guard let update = try? Agentkeyring_V1_TrustUpdate(serializedBytes: saved.update),
                let target = try? updateTarget(update) else { return nil }
            return RelayPermissionWithdrawal(id: id, kind: target.kind, revision: target.revision, label: saved.label,
                devices: saved.devices.map { deviceID, device in
                    RelayPermissionDeviceStatus(id: deviceID, label: device.label,
                        confirmed: device.receipt != nil, removedByLaterChange: device.retiredBy != nil)
                }.sorted { $0.label < $1.label }, isComplete: saved.completedAt != nil)
        }.sorted { $0.id < $1.id }
    }
}

extension RelayApproverState {
    var hasPendingWithdrawals: Bool { withdrawals?.values.contains(where: { $0.completedAt == nil }) == true }

    var withdrawalRetentionDeadline: Int64? {
        let referenced = Set((withdrawals ?? [:]).values.flatMap { $0.devices.values.compactMap(\.retiredBy) })
        return (withdrawals ?? [:]).compactMap { id, saved in
            guard !referenced.contains(id), let completed = saved.completedAt else { return nil }
            return completed + 7 * 86400
        }.min()
    }

    mutating func finishWithdrawals(now: Int64) {
        var changed = true
        while changed {
            changed = false
            for (id, var saved) in withdrawals ?? [:] where saved.completedAt == nil {
                for (deviceID, var device) in saved.devices where device.receipt == nil && device.retiredBy == nil {
                    if let later = withdrawals?.first(where: { otherID, other in
                        otherID != id && other.completedAt != nil && other.sequence > saved.sequence && other.removedDevices.contains(deviceID)
                    }) {
                        device.retiredBy = later.key
                        saved.devices[deviceID] = device
                        changed = true
                    }
                }
                if saved.devices.values.allSatisfy({ $0.receipt != nil || $0.retiredBy != nil }) {
                    saved.completedAt = now
                    changed = true
                }
                withdrawals![id] = saved
            }
        }
        var retained = Set((withdrawals ?? [:]).filter { _, saved in
            saved.completedAt == nil || saved.completedAt! + 7 * 86400 > now
        }.keys)
        var previous: Set<String> = []
        while retained != previous {
            previous = retained
            for id in previous {
                for dependency in withdrawals?[id]?.devices.values.compactMap(\.retiredBy) ?? [] { retained.insert(dependency) }
            }
        }
        withdrawals = withdrawals?.filter { retained.contains($0.key) }
    }
}
