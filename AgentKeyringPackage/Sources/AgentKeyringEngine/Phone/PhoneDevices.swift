// Written by AI on 2026.11.18 by model Claude Opus 5.5; edited on 2026.11.27 by model claude opus 5.5.
//
// Rules and devices changed here after Face ID, joining a Mac or another iPhone, notifications and
// settings, and resetting this iPhone.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import UserNotifications

@MainActor
extension PhoneKeyringEngine {
    // MARK: Rules and devices

    /// Changes a login's rule from the Passwords tab, after one Face ID. The Mac makes and withdraws the
    /// copies the new rule needs.
    public func setLoginRule(_ rule: LoginRule, forLogin loginID: String) async throws {
        try await setLoginRule(rule, forLogins: [loginID])
    }

    /// Batch-changes rules for multiple logins under one Face ID confirmation and one Catalogue revision.
    /// While contested, the merged list is still unsigned: the same rule again signs it, settling the contest.
    public func setLoginRule(_ rule: LoginRule, forLogins loginIDs: [String]) async throws {
        let wantedIDs = Set(loginIDs)
        guard !wantedIDs.isEmpty, let next = catalogue else { return }
        let wanted = rule.storedRule
        let changing = next.logins.filter { wantedIDs.contains($0.loginID) && $0.rule != wanted }
        guard !changing.isEmpty || state.catalogueContested else { return }
        let named = changing.isEmpty ? next.logins.filter { wantedIDs.contains($0.loginID) } : changing
        let context = LAContext()
        defer { context.invalidate() }
        let computers = members?.machines.map(\.label) ?? []
        let reason: String
        if named.count == 1, let single = named.first {
            reason = rule == .automatic && !computers.isEmpty && !changing.isEmpty
                ? PhoneCopy.automaticReason(site: Self.site(single), from: Self.rule(single), computers: computers)
                : PhoneCopy.faceIDSetRule(site: Self.site(single), rule: rule)
        } else {
            reason = PhoneCopy.faceIDSetRule(site: "\(named.count) passwords", rule: rule)
        }
        try await keys.authorize(context, reason: reason)
        // Another device's list taken meanwhile is merged in, and signed again under the same Face ID.
        for attempt in 0..<3 {
            do { return try await signRule(wanted, for: wantedIDs, context: context) }
            catch PhoneApprovalError.notAllowed(_) where attempt < 2 {
                KeyringDiagnosticLog.iPhone.noteDeviceEvent("rules", "signed again", ["attempt": "\(attempt + 1)"])
            }
        }
    }

    /// The merged list signed as the next revision after one Face ID, so a contest is settled with no Mac awake:
    /// every device and computer then goes by it.
    public func sendUnsentChanges() async throws {
        guard state.catalogueContested, catalogue != nil else { return }
        let context = LAContext()
        defer { context.invalidate() }
        try await keys.authorize(context, reason: PhoneCopy.faceIDSendUpdates)
        for attempt in 0..<3 {
            guard state.catalogueContested, let merged = catalogue else { return }
            do { return try await signAndShare(merged, automatic: [], context: context) }
            catch PhoneApprovalError.notAllowed(_) where attempt < 2 {
                KeyringDiagnosticLog.iPhone.noteDeviceEvent("rules", "signed again", ["attempt": "\(attempt + 1)"])
            }
        }
    }

    /// One attempt at `wanted` for these logins, on the catalogue as it is now (re-read after Face ID, or after
    /// another device's list was taken).
    private func signRule(_ wanted: Agentkeyring_V2_Rule, for wantedIDs: Set<String>, context: LAContext) async throws {
        guard var latest = catalogue else { return }
        let nowMs = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        let actor = state.deviceKeyID ?? ""
        var changedIDs: [String] = []
        for index in latest.logins.indices where wantedIDs.contains(latest.logins[index].loginID) && latest.logins[index].rule != wanted {
            latest.logins[index].rule = wanted
            latest.logins[index].ruleUpdatedUnixMs = max(nowMs, latest.logins[index].ruleUpdatedUnixMs + 1)
            latest.logins[index].ruleActor = actor
            if wanted == .blocked { latest.logins[index].version = 0 }
            changedIDs.append(latest.logins[index].loginID)
        }
        guard !changedIDs.isEmpty || state.catalogueContested else { return }
        try await signAndShare(latest, automatic: wanted == .automatic ? changedIDs : [], context: context)
    }

    /// Signs `next` as the revision after it and shares it. Enrolled computers' copies of the logins newly
    /// Automatic are sealed and uploaded first, so a Mac waking from CloudKit already sees its copy and never
    /// asks for a second Touch ID.
    private func signAndShare(_ next: Catalogue, automatic changedIDs: [String], context: LAContext) async throws {
        var latest = next
        latest.revision += 1
        let signed = try CredentialSealing.signedDocument(latest.serializedData(), by: CredentialSealing.keyID(keys.signingPublicKey())) { try keys.signWithDeviceKey($0, context: context) }
        let automaticCopies: [SealedLogin] = changedIDs.isEmpty ? [] : try sealAutomaticCopies(changedIDs, context: context)
        if !automaticCopies.isEmpty {
            await uploadMachineCopies(automaticCopies, catalogue: latest)
        }
        try await share(catalogue: signed)
        if !automaticCopies.isEmpty {
            keepMadeForOthers(automaticCopies)
            cloudSync.mailboxes.writeMailboxSlotsSoon()
            cloudSync.pushCloudSoon()
        }
        await sealMissingWatchCopies(context: context)
    }

    /// Removes a device or computer after Face ID: the removal every device makes
    /// (AgentKeyringEngine/Cloud/CloudDeviceRemoval.swift).
    public func removeDevice(device deviceID: String) async throws {
        guard let initial = members else { return }
        let context = LAContext()
        defer { context.invalidate() }
        let name = initial.devices.first { $0.keyID == deviceID }?.label ?? initial.machines.first { $0.machineID == deviceID }?.label ?? ""
        try await keys.authorize(context, reason: PhoneCopy.faceIDRemove(name))
        await cloudSync.pullCloudNow()
        do {
            try await cloudSync.removeDeviceAtomically(deviceID) { try keys.signWithDeviceKey($0, context: context) }
        } catch let failure as CloudDeviceRemovalError {
            throw PhoneApprovalError.notAllowed(Self.removalWords(failure))
        }
    }

    private static func removalWords(_ failure: CloudDeviceRemovalError) -> String {
        switch failure {
        case .thisDeviceRemoved: "This iPhone was removed from the keyring."
        case .cloudUnreachable: "Couldn't confirm the latest lists in iCloud. Try again."
        case .membersChangedFirst: "Another device changed the list of devices first."
        case .catalogueChangedFirst: "Another device changed the list first."
        case .membersChangedWhileRemoving: "The list of devices changed while removing. Try again."
        }
    }

    /// What this iPhone signs its sealed copies with: its reply key, which needs no Face ID.
    var sealSigner: PayloadReplySigner {
        PayloadReplySigner(keyID: (try? CredentialSealing.keyID(keys.replyPublicKey())) ?? "", sign: keys.signReply)
    }

    // MARK: Joining a Mac or another iPhone

    /// The join card in iCloud Keychain. Nil when there is none, for example in the simulator, which has no
    /// iCloud Keychain.
    func joinCard() -> Agentkeyring_V2_JoinInvite? { invitationStore.read() }

    /// A card that can be joined, through iCloud: another device's, with a secret that has not run out. This
    /// iPhone's own card, left before the app was removed and installed again, is never one.
    func joinable(_ card: Agentkeyring_V2_JoinInvite) -> Bool {
        let own = try? CredentialSealing.keyID(keys.signingPublicKey())
        return !card.secret.isEmpty && card.inviterKeyID != own && card.expiresUnixSeconds > Int64(Date().timeIntervalSince1970)
    }

    /// Reads the Mac's join card every second, then every three, while first run looks for it. The read is
    /// local; a card iCloud has just brought may take a moment, so three seconds with nothing is `noMacFound`.
    func lookForMac() {
        guard looking == nil, state.deviceKeyID == nil else { return }
        let since = Date()
        looking = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.firstRun.looksForMac, self.state.deviceKeyID == nil else { break }
                if let card = self.joinCard(), self.joinable(card) {
                    self.foundMac = card
                    self.apply(.macFound(name: card.inviterLabel.isEmpty ? nil : card.inviterLabel))
                } else {
                    self.foundMac = nil
                    self.apply(.macGone)
                    if Date().timeIntervalSince(since) >= 3 { self.apply(.noMacFound) }
                }
                try? await Task.sleep(for: .seconds(Date().timeIntervalSince(since) < 3 ? 1 : 3))
            }
            self?.looking = nil
        }
    }


    /// This iPhone as it asks to join.
    func joinRequest(_ card: Agentkeyring_V2_JoinInvite) throws -> Agentkeyring_V2_JoinRequest {
        var joining = Agentkeyring_V2_JoinRequest()
        joining.device = try thisDevice()
        joining.proof = CredentialSealing.joinProof(secret: card.secret, joining: joining)
        return joining
    }

    /// Asks to join through iCloud (PhoneVault.swift, `joinThroughCloud`), with the card the look found.
    func joinMac() {
        guard joining == nil, state.deviceKeyID == nil else { return }
        joiningGeneration &+= 1
        let generation = joiningGeneration
        joining = Task { [weak self] in
            defer {
                if self?.joiningGeneration == generation { self?.joining = nil }
            }
            await self?.withdrawing?.value
            guard !Task.isCancelled, let self, self.joiningGeneration == generation, self.firstRun.mayJoin,
                  let card = self.foundMac ?? self.joinCard(), self.joinable(card) else {
                if let self, !Task.isCancelled, self.joiningGeneration == generation, self.firstRun.mayJoin { self.apply(.macUnreachable) }
                return
            }
            await self.joinThroughCloud(card, generation: generation)
        }
    }


    func startReceivingPasswords() {
        guard receivingTask == nil else { return }
        receivingTask = Task { [weak self] in
            defer { self?.receivingTask = nil }
            await self?.receivePasswords()
        }
    }

    /// Cancel while waiting: the request goes from iCloud, which the inviter reads as withdrawn.
    /// `joining` is already cancelled synchronously in `apply(.cancel)` so an immediate reconnect starts cleanly.
    func withdrawJoin() async {
        guard let me = try? keys.signingPublicKey() else { return }
        try? await cloudSync.cloud?.deleteCloudRecords([CloudRecordKind.join(CredentialSealing.keyID(me))])
    }

    /// Added: fetches this iPhone's copies until every password not Blocked has one, then first run goes on.
    /// The inviter may still be encrypting them; after a minute with no more arriving, first run goes on anyway
    /// and the rest come with the next fetch.
    func receivePasswords() async {
        var lastCount = -1
        var lastGrowth = Date()
        while firstRun == .receivingPasswords {
            if await refresh(), let expected = copiesExpected, copiesHeld >= expected { break }
            if copiesHeld != lastCount { lastCount = copiesHeld; lastGrowth = Date() }
            if Date().timeIntervalSince(lastGrowth) > 60 {
                KeyringDiagnosticLog.iPhone.noteDeviceEvent("join", "copies incomplete", ["held": "\(copiesHeld)", "expected": "\(copiesExpected ?? 0)"])
                break
            }
            try? await Task.sleep(for: .seconds(2))
        }
        apply(.passwordsReceived)
    }

    // MARK: Notifications


    public func checkNotifications() async -> PhoneNotificationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let read = PhoneNotificationFacts(settings)
        notificationFacts(read)
        return PhoneNotificationStatus(asked: settings.authorizationStatus != .notDetermined, facts: read)
    }

    public func askForNotifications() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let allowed: Bool
        do { allowed = try await center.requestAuthorization(options: [.alert, .sound, .badge]) } catch {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("notifications", "not asked", ["error": "\(error)"])
            allowed = false
        }
        notificationFacts(PhoneNotificationFacts(await center.notificationSettings()))
        return allowed
    }

    func notificationFacts(_ next: PhoneNotificationFacts) {
        guard next != facts else { return }
        facts = next
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("notifications", "read", ["allowed": "\(next.allowed)", "banners": "\(next.banners)",
            "lockScreen": "\(next.lockScreen)", "timeSensitive": "\(next.timeSensitive)", "scheduledSummary": "\(next.inScheduledSummary)"])
    }

    var phoneSettings: PhoneSettings {
        let saved = state.settings ?? NotificationSettings()
        return PhoneSettings(timeSensitive: saved.timeSensitive, quietHours: saved.quietHours, quietFrom: saved.quietFrom, quietTo: saved.quietTo,
                             remindToUpdate: state.remindToUpdate == true, anonymousTelemetry: !VersionCheck.isDisabled)
    }

    /// Kept for the extension in the shared keychain item, and handed to Apple Watch.
    public func savePhoneSettings(_ settings: PhoneSettings) async {
        var saved = NotificationSettings()
        saved.timeSensitive = settings.timeSensitive; saved.quietHours = settings.quietHours
        saved.quietFrom = settings.quietFrom; saved.quietTo = settings.quietTo
        var next = state
        next.settings = saved
        next.remindToUpdate = settings.remindToUpdate
        if settings.anonymousTelemetry == VersionCheck.isDisabled { VersionCheck.setNoTelemetry(!settings.anonymousTelemetry) }
        save(next)
        scheduleReminder()
        onListsChanged?()
        publish()
    }

    /// Beside the state file, which a reset replaces; removing the app removes it, so a new install starts over too.
    private var watchResetURL: URL { directory.appending(path: "watch-reset") }

    var watchResetSaved: Bool { FileManager.default.fileExists(atPath: watchResetURL.path) }

    /// When this iPhone last started over, sent to Apple Watch so a Watch holding an older keyring wipes cleanly.
    public var watchResetAt: Double {
        (try? String(contentsOf: watchResetURL, encoding: .utf8)).flatMap(Double.init) ?? 0
    }

    /// Marks a reset, a removal or a new install, always later than the last one.
    func recordWatchReset() {
        let next = max(Date().timeIntervalSince1970, watchResetAt + 1)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try String(next).write(to: watchResetURL, atomically: true, encoding: .utf8)
        } catch {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("watch", "reset not saved", ["error": "\(error)"])
        }
    }

    /// Drops the cached iCloud change token and pulls/pushes everything fresh.
    public func syncWithICloudNow() async {
        cloudSync.readWholeCloudNext()
        _ = await refresh()
        cloudSync.pushCloudSoon()
        onListsChanged?()
    }

    /// Cancels all active tasks and clears all in-memory runtime caches (used on device removal and reset).
    func clearRuntimeState() {
        cloudSync.forgetRuntimeState()
        looking?.cancel(); looking = nil
        joiningGeneration &+= 1
        joining?.cancel(); joining = nil
        withdrawing?.cancel(); withdrawing = nil
        addingComputer?.cancel(); addingComputer = nil
        addingWatchGeneration &+= 1
        watchEnrollment.hold?.invalidate()
        watchEnrollment.encryptionTask?.cancel()
        watchEnrollment = .none
        receivingTask?.cancel(); receivingTask = nil
        practiceTask?.cancel(); practiceTask = nil
        practiceTimer?.cancel(); practiceTimer = nil
        for task in practiceBoxTasks.values { task.cancel() }
        practiceBoxTasks.removeAll()
        watchCopiesSyncing?.cancel(); watchCopiesSyncing = nil
        requestExpiryTimer?.cancel(); requestExpiryTimer = nil
        categorySortingTask?.cancel(); categorySortingTask = nil
        pushRegistering?.cancel(); pushRegistering = nil

        handledImportTokens.removeAll()
        practiceAsks.removeAll()
        practiceEnded.removeAll()
        inFlightAnswers.removeAll()
        undelivered.removeAll()
        unverifiedRequestEnvelopes.removeAll()
        watchDismissedIDs.removeAll()
        foundMac = nil
        addComputerFlow = nil
        computerJoin = nil
        approvingComputer = false
        addingDevice = nil
        copiesHeld = 0
        copiesExpected = nil
        pushState = .none
        passwordsCopy = PhonePasswordsCopy()
        onWatchMayAsk?()
    }

    /// Clears local state on this iPhone (and notifies paired Apple Watch to wipe too), returning to first-run setup.
    /// When `includingICloud` is true, also deletes the AgentKeyringVault CloudKit zone and iCloud Keychain invitation.
    public func resetKeyring(includingICloud: Bool) async throws {
        clearRuntimeState()

        if includingICloud {
            try await cloudSync.cloud?.deleteCloudZone()
            invitationStore.remove()
        } else {
            cloudSync.cloud?.forgetLocalCloudState()
            let ownKeyID = try? CredentialSealing.keyID(keys.signingPublicKey())
            if let ownKeyID, joinCard()?.inviterKeyID == ownKeyID { invitationStore.remove() }
        }

        shared.deleteSharedContext()
        recordWatchReset()
        stateFileLocked = false
        guard save(PhoneSavedState()) else {
            throw PhoneApprovalError.notAllowed("Couldn't save the reset state on this iPhone.")
        }
        onListsChanged?()
        apply(.removed)
        startBackgroundWork()
    }

    public var notificationSettings: NotificationSettings { state.settings ?? NotificationSettings() }
}

extension PhoneNotificationFacts {
    init(_ settings: UNNotificationSettings) {
        self.init()
        allowed = settings.authorizationStatus == .authorized
        banners = settings.alertSetting == .enabled
        lockScreen = settings.lockScreenSetting == .enabled
        timeSensitive = settings.timeSensitiveSetting == .enabled
        inScheduledSummary = settings.scheduledDeliverySetting == .enabled
    }
}

extension PhoneKeyringEngine: CloudDeviceRemovalHost {
    package func removalCatalogueBase() async -> DeviceRemovalCatalogueBase {
        let merged = catalogue ?? Catalogue()
        return DeviceRemovalCatalogueBase(held: state.catalogue, contested: state.contestedCatalogues, merged: merged,
                                          nextRevision: merged.revision + 1)
    }

    /// Only computers leave: the next Members goes to iCloud first, unless this iPhone is signed out of it.
    package func publishMembersRemovingComputers(_ next: Members, signed: Data) async throws {
        let availability = await cloudSync.cloud?.availability()
        try await share(members: SignedDocument(serializedBytes: signed),
                        requireCloud: cloudSync.cloud != nil && availability != .signedOut)
    }

    package func receiveSignedMembersDuringRemoval(_ signed: Data) async -> PeerIntakeOutcome { receiveSignedMembers(signed) }

    /// Members before the catalogue, so a catalogue taken meanwhile at the same or a later revision cannot skip
    /// the revocation.
    package func adoptDeviceRemoval(_ removal: SignedDeviceRemoval, committedInCloud: Bool) async throws -> Bool {
        guard committedInCloud || state.members == removal.preMembersBytes else { return false }
        try receiveSignedMembers(removal.signedMembersBytes).requireTaken()
        if committedInCloud {
            updateReplica {
                $0.cloudAcceptedMembers = removal.signedMembersBytes
                $0.cloudAcceptedCatalogue = removal.signedCatalogueBytes
                $0.cloudCheckpoint.noteWritten([CloudRecordKind.members, CloudRecordKind.catalogue])
            }
        }
        _ = receiveSignedCatalogue(removal.signedCatalogueBytes)
        cloudSync.pushCloudSoon()
        return true
    }
}
