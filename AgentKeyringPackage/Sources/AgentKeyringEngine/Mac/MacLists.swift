// Written by AI on 2026.11.18 by model claude opus 5.5; edited on 2026.11.27 by model claude opus 5.5.
//
// The lists this Mac serves to computers, and what it takes from the other
// devices: their push addresses, newer members lists and catalogues, and the
// copies they sealed.

#if os(macOS)
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation

@MainActor
extension MacSyncCoordinator {
    // MARK: Lists served

    public var revisions: Agentkeyring_V2_Revisions {
        var revisions = Agentkeyring_V2_Revisions()
        revisions.members = members?.revision ?? 0
        revisions.catalogue = catalogue?.revision ?? 0
        revisions.copies = saved.copiesRevision
        return revisions
    }

    /// Everything a computer keeps: the lists, every members revision it lacks, the push addresses, its own
    /// copies of the passwords Automatic for it, and a Freshness. Only copies of the signed catalogue's current
    /// version are given, never a Blocked one: an import Josh has not yet approved sending stays here.
    /// `holding`: the newest members revision the computer has; every later one comes too, oldest first.
    func bundle(for machine: Agentkeyring_V2_Machine, holding: UInt64) async -> Agentkeyring_V2_Bundle {
        var bundle = Agentkeyring_V2_Bundle()
        if let bytes = saved.members, let signed = try? Agentkeyring_V2_Signed(serializedBytes: bytes) { bundle.members = signed }
        bundle.membersSince = saved.membersHistory.compactMap { try? Agentkeyring_V2_Signed(serializedBytes: $0) }.filter { signed in
            ((try? Agentkeyring_V2_Members(serializedBytes: signed.payload))?.revision ?? 0) > holding
        }
        if let bytes = saved.catalogue, let signed = try? Agentkeyring_V2_Signed(serializedBytes: bytes) { bundle.catalogue = signed }
        bundle.pushRegistrations = saved.pushRegistrations.keys.sorted().compactMap { saved.pushRegistrations[$0].flatMap { try? Agentkeyring_V2_Signed(serializedBytes: $0) } }
        bundle.revisions = revisions
        guard let catalogue, members != nil else { return bundle }
        let listed = Dictionary(catalogue.logins.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
        bundle.copies = ((try? await store.sealed()) ?? []).filter { copy in
            guard let login = listed[copy.loginID], login.holdsSecret, login.version == copy.version else { return false }
            return copy.openerID == machine.machineID && login.rule == .automatic
        }
        if let fresh = cloudSync.mailboxes.signedFreshness(for: machine.machineID) { bundle.freshness = fresh }
        return bundle
    }

    /// The lists or a copy changed: the iPhone hears it from a silent push, a second later, and reads iCloud.
    /// Computers' mailboxes are written once iCloud has taken the lists (AgentKeyringEngine/Cloud/CloudReplicaPush.swift, pushCloudNow).
    func listsChanged(copies: Bool = false) {
        if copies { saved.copiesRevision += 1; scheduleCountOwnCopies() }
        persist()
        cloudSync.pushCloudSoon()
        if cloudSync.cloud == nil { cloudSync.mailboxes.writeMailboxSlotsSoon() }
        revPush?.cancel()
        revPush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.sendRevisionsPush()
        }
    }

    private func sendRevisionsPush() async {
        guard let push, let members else { return }
        let payload = PushPayload.revisions(revisions)
        for phone in members.devices where phone.kind == .iphone {
            guard let registration = registration(for: phone.keyID) else { continue }
            do {
                try await push.sendPush(payload, to: registration, collapseID: "rev", expiration: Int64(Date.now.timeIntervalSince1970) + 86400, visible: false)
            } catch let failure as ApplePushError where failure.invalidToken {
                if self.registration(for: phone.keyID)?.apnsToken == registration.apnsToken {
                    saved.pushRegistrations.removeValue(forKey: phone.keyID)
                    persist()
                    cloudSync.pushCloudSoon()
                }
                KeyringDiagnosticLog.mac.noteDeviceEvent("push", "address-gone", ["device": phone.label, "reason": failure.reason])
            } catch {
                KeyringDiagnosticLog.mac.noteDeviceEvent("push", "rev-not-sent", ["device": phone.label, "reason": "\(error)"])
            }
        }
    }

    func registration(for deviceKeyID: String) -> Agentkeyring_V2_PushRegistration? {
        saved.pushRegistrations[deviceKeyID].flatMap { try? Agentkeyring_V2_Signed(serializedBytes: $0) }
            .flatMap { try? Agentkeyring_V2_PushRegistration(serializedBytes: $0.payload) }
    }

    /// True when this Mac has received a signed APNs push registration for `deviceKeyID`.
    public func hasPushRegistration(for deviceKeyID: String) -> Bool {
        registration(for: deviceKeyID) != nil
    }

    /// A signed document from a device in the members list, by its reply key or signing key.
    func fromDevice(_ body: Data) -> (document: Agentkeyring_V2_Signed, device: Agentkeyring_V2_Device)? {
        guard let members, let document = try? Agentkeyring_V2_Signed(serializedBytes: body),
            let device = try? CredentialSealing.verifySignedDocument(document, members: members, allowReplyKey: true) else { return nil }
        return (document, device)
    }

    // MARK: What devices send

    /// A newer members list another device signed, checked against the one held, once no other change to
    /// Members is under way here.
    @discardableResult
    package func receiveSignedMembers(_ body: Data) async -> PeerIntakeOutcome {
        guard let document = try? Agentkeyring_V2_Signed(serializedBytes: body) else { return .refused("The body must be a signed members list.") }
        return (try? await withSerializedMembers {
            await self.adoptSignedMembers(document, body: body)
        }) ?? .refused("This members list was refused.")
    }

    /// As `receiveSignedMembers`, for a device removal that already holds the lock on Members.
    package func receiveSignedMembersDuringRemoval(_ body: Data) async -> PeerIntakeOutcome {
        guard let document = try? Agentkeyring_V2_Signed(serializedBytes: body) else { return .refused("The body must be a signed members list.") }
        return await adoptSignedMembers(document, body: body)
    }

    private func adoptSignedMembers(_ document: Agentkeyring_V2_Signed, body: Data) async -> PeerIntakeOutcome {
        do {
            let next = try CredentialSealing.verifySignedMembers(document, current: members)
            guard await adoptMembers(next, signed: body) else { return .notSaved("This Mac could not save the list of devices.") }
            return .taken
        } catch {
            return .refused("This members list was refused: \(error).")
        }
    }

    /// A newer members list, signed here or on the iPhone. A device or computer it leaves out keeps nothing here.
    /// False, with nothing changed, when it could not be saved: a removed device must not come back on relaunch.
    @discardableResult
    func adoptMembers(_ next: Agentkeyring_V2_Members, signed: Data) async -> Bool {
        let known = Set(next.devices.map(\.keyID) + next.machines.map(\.machineID))
        guard updateReplica({ $0.adoptMembers(next, signed: signed) }) else {
            KeyringDiagnosticLog.mac.noteDeviceEvent("members", "not-saved", ["revision": "\(next.revision)"])
            return false
        }
        members = next
        let ownDeviceKeyID = keys.deviceKeyID
        _ = try? await store.updateSealed { current in
            guard current.contains(where: { !known.contains($0.openerID) && $0.openerID != ownDeviceKeyID }) else { return current }
            return current.filter { known.contains($0.openerID) || $0.openerID == ownDeviceKeyID }
        }
        KeyringDiagnosticLog.mac.noteDeviceEvent("members", "changed", ["revision": "\(next.revision)", "devices": "\(next.devices.count)", "computers": "\(next.machines.count)"])
        listsChanged(copies: true)
        await onAutomaticCopiesChanged?()
        return true
    }

    /// A catalogue another device signed. A later one is taken. One signed elsewhere while apart, of the same
    /// revision or one that sets a rule this Mac has not seen, is kept beside this Mac's: the two are merged, the
    /// later change to each password winning, and the merged list waits to be signed here as the next revision.
    /// Nothing is kept unless the rules and copies it changes are saved: `notSaved`, to be taken again.
    @discardableResult
    package func receiveSignedCatalogue(_ body: Data) async -> PeerIntakeOutcome {
        await withSerializedCatalogue { [self] in
            guard let members else {
                return .refused("A catalogue comes after the list of devices.")
            }
            let previous = catalogue
            let before = (saved.catalogue, saved.contestedCatalogues, saved.catalogueRevision)
            let intake: CatalogueIntake
            do { intake = try saved.intakeCatalogue(body, members: members) } catch {
                return .refused("This catalogue was refused: \(error).")
            }
            guard intake == .newer || intake == .contested else {
                return .refused("This catalogue was refused: it is not newer than the one held.")
            }
            // The merge, never theirs alone: a Block or an Automatic copy made here stays.
            catalogue = saved.effectiveCatalogue
            saved.catalogueRevision = max(saved.catalogueRevision, catalogue?.revision ?? 0)
            do {
                if let catalogue { try await onCatalogue?(catalogue, previous) }
            } catch {
                (saved.catalogue, saved.contestedCatalogues, saved.catalogueRevision) = before
                catalogue = previous
                KeyringDiagnosticLog.mac.noteDeviceEvent("catalogue", "not-saved", ["reason": "\(error)"])
                return .notSaved("\(error)")
            }
            listsChanged(copies: true)
            if intake == .contested {
                KeyringDiagnosticLog.mac.noteDeviceEvent("cloud", "catalogue-conflict", ["revision": "\(catalogue?.revision ?? 0)"])
                onCatalogueConflict?()
            } else {
                KeyringDiagnosticLog.mac.noteDeviceEvent("catalogue", "changed", ["revision": "\(catalogue?.revision ?? 0)"])
            }
            return .taken
        }
    }

    /// Copies made on another device: a computer's Automatic ones, or this Mac's own of a password exported
    /// on that device. Each is checked against its signer and the catalogue's version. A copy sealed to this
    /// Mac never replaces one it holds: it is kept beside them, and the newest is used.
    @discardableResult
    func receiveSealedCopies(_ body: Data) async -> Bool {
        guard let members, let catalogue, let batch = try? Agentkeyring_V2_SealedLogins(serializedBytes: body) else {
            return false
        }
        let listed = Dictionary(catalogue.logins.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
        let own = keys.deviceKeyID
        let openers = Set(members.devices.map(\.keyID) + members.machines.map(\.machineID))
        var kept: [Agentkeyring_V2_SealedLogin] = []
        for copy in batch.logins {
            guard openers.contains(copy.openerID), let login = listed[copy.loginID] else { return false }
            guard login.holdsSecret, copy.openerID != own || copy.signerKeyID != keys.replyKeyID else { continue }
            do { try CredentialSealing.verifySealedLogin(copy, members: members, listed: login) } catch {
                return false
            }
            kept.append(copy)
        }
        let cleared = Set(batch.clearedOpeners).intersection(openers).subtracting([own])
        let machines = Set(members.machines.map(\.machineID))
        let withdrawn = Set(batch.withdrawnLoginIds)
        let replaced = Set(kept.filter { $0.openerID != own }.map { $0.openerID + "/" + $0.loginID })
        let incoming = kept
        do {
            _ = try await store.updateSealed { current in
                var next = current
                next.removeAll { cleared.contains($0.openerID) || (withdrawn.contains($0.loginID) && machines.contains($0.openerID)) }
                next.removeAll { replaced.contains($0.openerID + "/" + $0.loginID) }
                let held = Set(next.filter { $0.openerID == own }.map { "\($0.loginID)/\($0.version)" })
                return next + incoming.filter { $0.openerID != own || !held.contains("\($0.loginID)/\($0.version)") }
            }
        } catch {
            KeyringDiagnosticLog.mac.noteDeviceEvent("copies", "not saved", ["reason": "\(error)"])
            return false
        }
        listsChanged(copies: true)
        if kept.contains(where: { $0.openerID == own || machines.contains($0.openerID) }) || !cleared.isEmpty || !withdrawn.isEmpty {
            await onAutomaticCopiesChanged?()
        }
        return true
    }
}
#endif
