// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// What a copy from Passwords changed since the other devices last received
// the list (docs/state-machines.md, "Sending changes to the other devices").
// The record of the list last sent is saved, so what is unsent survives a
// quit: it is always the current list against that record.

import Foundation
import LocalAuthentication

@available(macOS 26.0, *)
extension MirrorAppModel {
    static let sentListKey = "sentList"

    /// The list the other devices last received, as saved: each password's id
    /// and its last-changed date (nil when not known). Nil before any device joined.
    static func savedSentList(_ settings: UserDefaults) -> [String: Date?]? {
        guard let data = settings.data(forKey: sentListKey) else { return nil }
        return try? JSONDecoder().decode([String: Date?].self, from: data)
    }

    static func saveSentList(_ list: [String: Date?]?, in settings: UserDefaults) {
        settings.set(list.flatMap { try? JSONEncoder().encode($0) }, forKey: sentListKey)
    }

    /// The list as it is now, by id and last-changed date.
    var currentList: [String: Date?] {
        Dictionary(leaseLogins.map { ($0.id.uuidString, $0.lastModifiedAt) }, uniquingKeysWith: { first, _ in first })
    }

    /// Another device or computer holds a copy of the list.
    public var hasOtherDevices: Bool {
        guard let device, let members = device.members else { return false }
        return members.devices.contains { $0.keyID != device.ownDeviceID } || members.machines.contains { $0.machineID != device.ownMachineID }
    }

    /// What the other devices have not been sent yet. Nothing when no other device holds the list.
    public var unsentChanges: PasswordChanges {
        guard hasOtherDevices else { return PasswordChanges() }
        var base = sentList.map { PasswordChanges(sent: $0, now: currentList) } ?? PasswordChanges()
        if !pendingAutomaticCatalogueLoginIDs.isEmpty {
            let alreadyCounted: Set<String> = if let sentList {
                Set(currentList.compactMap { id, date -> String? in
                    guard let recorded = sentList[id] else { return id }
                    if let recorded, date != recorded { return id }
                    return nil
                })
            } else {
                []
            }
            base.changed += pendingAutomaticCatalogueLoginIDs.subtracting(alreadyCounted).count
        }
        return base
    }

    /// The catalogue was signed and sent: record the exact snapshot that was signed so a concurrent import stays unsent.
    func recordSentList() {
        sentList = publishingListSnapshot ?? currentList
        publishingListSnapshot = nil
        resyncAsked = false
    }

    /// A Mac whose devices joined before the record was kept: the signed
    /// catalogue says which passwords they hold, with no dates.
    func seedSentList() {
        guard sentList == nil, let catalogue = device?.catalogue else { return }
        sentList = Dictionary(catalogue.logins.map { ($0.loginID, Date?.none) }, uniquingKeysWith: { first, _ in first })
    }

    /// After a copy from Passwords, and Devices' Send Updates: ask to send the
    /// changes, if another device holds the list and something changed.
    public func askToSendChanges() {
        resyncAsked = unsentChanges.total > 0
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

    /// Not Now: the other devices keep the list they hold, and the changes stay unsent.
    public func declineSendingChanges() {
        resyncAsked = false
    }
}
