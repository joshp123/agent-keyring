// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// What a copy from Passwords changed since the other devices last received
// the list (docs/state-machines.md, "Sending changes to the other devices").
// The record of the list last sent is saved, so what is unsent survives a
// quit: it is always the current list against that record.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import LocalAuthentication

@available(macOS 26.0, *)
extension MacKeyringEngine {
    static let sentListKey = "sentList"
    static let sentListProtobufMagic = Data("AKRSL02".utf8)

    /// The list the other devices last received, as saved: each password's id
    /// and its last-changed date (nil when not known). Nil before any device joined.
    static func savedSentList(_ settings: UserDefaults) -> [String: Date?]? {
        guard let data = settings.data(forKey: sentListKey), data.starts(with: sentListProtobufMagic),
              let proto = try? Agentkeyring_V2_StoredSentList(serializedBytes: Data(data.dropFirst(sentListProtobufMagic.count)))
        else { return nil }
        var list: [String: Date?] = [:]
        for entry in proto.entries {
            let date: Date? = entry.hasLastModifiedUnixSeconds ? Date(timeIntervalSince1970: entry.lastModifiedUnixSeconds) : nil
            list[entry.loginID] = date
        }
        return list
    }

    static func saveSentList(_ list: [String: Date?]?, in settings: UserDefaults) {
        guard let list else {
            settings.removeObject(forKey: sentListKey)
            return
        }
        var proto = Agentkeyring_V2_StoredSentList()
        proto.entries = list.keys.sorted().map { loginID in
            var entry = Agentkeyring_V2_StoredSentListEntry()
            entry.loginID = loginID
            if let date = list[loginID] ?? nil {
                entry.lastModifiedUnixSeconds = date.timeIntervalSince1970
            }
            return entry
        }
        let encoded = (try? proto.serializedData()).map { sentListProtobufMagic + $0 }
        settings.set(encoded, forKey: sentListKey)
    }

    /// The list as it is now, by id and last-changed date.
    var currentList: [String: Date?] {
        Dictionary(leaseLogins.map { ($0.id.uuidString, $0.lastModifiedAt) }, uniquingKeysWith: { first, _ in first })
    }

    /// Another device or computer holds a copy of the list.
    var hasOtherDevices: Bool {
        guard let device, let members = device.members else { return false }
        return members.devices.contains { $0.keyID != device.ownDeviceID } || members.machines.contains { $0.machineID != device.ownMachineID }
    }

    /// Passwords whose rule, or whether any device holds the password, is not
    /// what the other devices were last sent: a rule merged from the iPhone,
    /// or a password copied again since it was unblocked.
    var catalogueDiffers: Set<String> {
        guard let catalogue = device?.catalogue else { return [] }
        return Self.differs(sent: catalogue.logins, here: leaseLogins, rule: accessControl.rule(for:))
    }

    static func differs(sent: [Agentkeyring_V2_Login], here: [CredentialCandidate],
                        rule: (UUID) -> LoginRule) -> Set<String> {
        let signed = Dictionary(sent.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(here.compactMap { login -> String? in
            let id = login.id.uuidString
            guard let sent = signed[id] else { return nil }
            let wanted = rule(login.id).storedRule
            let holds = wanted != .blocked && !login.isSecretDeleted
            return sent.rule != wanted || sent.holdsSecret != holds ? id : nil
        })
    }

    /// What the other devices have not been sent yet. Nothing when no other device holds the list.
    public var unsentChanges: UnsentVaultChanges {
        guard hasOtherDevices else { return UnsentVaultChanges() }
        var base = sentList.map { UnsentVaultChanges(sent: $0, now: currentList) } ?? UnsentVaultChanges()
        let alreadyCounted: Set<String> = if let sentList {
            Set(currentList.compactMap { id, date -> String? in
                guard let recorded = sentList[id] else { return id }
                if let recorded, date != recorded { return id }
                return nil
            })
        } else {
            []
        }
        base.changed += catalogueDiffers.subtracting(alreadyCounted).count
        // A contest is settled only by signing the next revision. The merged list already matches this Mac's
        // rules, so nothing above differs; it still has to be sent once.
        if base.total == 0, device?.saved.catalogueContested == true { base.changed = 1 }
        return base
    }

    /// The catalogue was signed and sent: record the exact snapshot that was signed so a concurrent import stays unsent.
    func recordSentList() {
        sentList = publishingListSnapshot ?? currentList
        publishingListSnapshot = nil
    }

    /// Right after a copy from Passwords, and Devices' Send Updates: one Touch ID (or this Mac's password)
    /// signs the list and sends it to the other devices, if another device holds it and something changed.
    /// Cancelled or failed, the changes stay unsent and Devices offers to send them. Never inside the
    /// catalogue's serializer: `publish` takes it itself.
    func publishChanges() async {
        do {
            try await publishChangesThrowing()
        } catch {
            KeyringDiagnosticLog.mac.noteDeviceEvent("copy", "not-sent", ["reason": "\(error)"])
        }
    }

    public func publishChangesThrowing() async throws {
        let changes = unsentChanges
        guard !sendingChanges, changes.total > 0 else { return }
        sendingChanges = true
        defer { sendingChanges = false }
        let context = LAContext()
        defer { context.invalidate() }
        let reason = MessageCopy.sendChangesReason(added: changes.added, changed: changes.changed, removed: changes.removed)
        do {
            try await confirmOwner(context, reason: reason)
            try await sendChanges(context: context)
            KeyringDiagnosticLog.mac.noteDeviceEvent("copy", "sent", [:])
        } catch let error as CredentialReleaseAuthorizationError where error.isCancel {
            throw CancellationError()
        }
    }

    /// Touch ID on the panel: the catalogue is signed and sent, and any enrolled computer lacking
    /// the newly published Automatic copies gets them immediately under the same Touch ID confirmation.
    public func sendChanges(context: LAContext) async throws {
        try await device?.publish(context: context)
        if !(await missingAutomaticCopies()).isEmpty {
            try await sealAutomaticCopies(context: context)
        } else {
            await noteMissingAutomaticCopies()
        }
    }

}
#endif
