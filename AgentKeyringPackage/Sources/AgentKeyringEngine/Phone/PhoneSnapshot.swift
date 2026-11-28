// Written by AI on 2026.11.18 by model Claude Opus 5.5; edited on 2026.11.27 by model claude opus 5.5.
//
// What the screens see: one snapshot of everything, sent to every screen on each change.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication

@MainActor
extension PhoneKeyringEngine {
    // MARK: What the screens see

    public func phoneSnapshotUpdates() -> AsyncStream<PhoneSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers.removeValue(forKey: id) } }
        }
    }

    public var snapshot: PhoneSnapshot {
        var snapshot = PhoneSnapshot(firstRun: firstRun, practiceRequest: practiceOpen)
        snapshot.revision = snapshotRevision
        snapshot.practiceDeniedReply = state.lastPracticeReply
        snapshot.settings = phoneSettings
        snapshot.notificationFacts = facts
        snapshot.addWatch = addWatchFlow
        snapshot.macName = foundMac.flatMap { $0.inviterLabel.isEmpty ? nil : $0.inviterLabel }
        snapshot.passwordsCopy = passwordsCopyFacts
        snapshot.addComputer = addComputerFlow
        guard let members, state.deviceKeyID != nil else { return snapshot }
        let catalogue = self.catalogue
        let envelopes = state.requestEnvelopes.values.compactMap { try? Agentkeyring_V2_SignedRequestEnvelope(serializedBytes: $0) }
        snapshot.requests = envelopes.compactMap { accessRequest($0, members, catalogue) }
        let inUse = Dictionary(grouping: envelopes.compactMap { envelope -> String? in
            guard let request = try? CredentialSealing.parseRequest(envelope.request),
                  accessRequest(envelope, members, catalogue)?.state.isInUse == true else { return nil }
            return request.loginID
        }, by: { $0 }).mapValues(\.count)
        snapshot.logins = (catalogue?.logins ?? []).map { login in
            let site = Self.site(login)
            let category = DomainClassifier.classify(site: site)
                ?? OnDeviceCategoryClassifier.shared.cachedCategory(forSite: site)
                ?? .other
            return PhoneLogin(id: login.loginID, site: site, account: login.account, rule: Self.rule(login),
                categoryID: category.rawValue,
                secretDeleted: login.rule != .blocked && login.version == 0,
                activeLeases: inUse[login.loginID] ?? 0)
        }
        snapshot.devices = Self.listed(members, thisDeviceID: state.deviceKeyID).phoneDevices(readiness: { approver in
            if approver.device.kind == .watch && (watchCopiesPending || isCopyingToWatch) {
                if case let .encrypting(done, total) = addWatchFlow { return .syncingCopies(done: done, total: total) }
                return .syncingCopies(done: copiesForWatch.count, total: catalogue?.logins.filter(\.holdsSecret).count ?? 0)
            }
            return pushRegistration(for: approver.id) == nil ? .waitingForNotifications : .ready
        }, practice: { devicePracticeStatus(for: $0.id) })
        snapshot.joined = true
        snapshot.hasComputer = !members.machines.isEmpty || members.devices.contains { $0.kind == .mac }
        snapshot.deviceJoin = deviceJoinShown
        snapshot.watch = watchFacts(members)
        if !pushRegistered && !state.pushSeen { snapshot.notices.append(.stillConnecting) }
        if cloudSync.state == .signedOut, members.devices.count > 1 { snapshot.notices.append(.iCloudSignedOut) }
        snapshot.undelivered = undelivered
        snapshot.hasUnsentUpdates = state.catalogueContested
        if let copiesExpected, copiesHeld < copiesExpected { snapshot.filling = PhoneFill(copied: copiesHeld, of: copiesExpected) }
        return snapshot
    }

    /// The members list as both screens list it: a Mac whose agents also ask is one row, and its Remove takes both.
    nonisolated static func listed(_ members: Members, thisDeviceID: String?) -> DevicesSnapshot {
        let devices = members.devices.compactMap { device -> SignedListDevice? in
            let kind: SignedListDeviceKind? = switch device.kind {
            case .iphone: .iPhone
            case .watch: .watch
            case .mac: .mac
            case .unspecified, .UNRECOGNIZED: nil
            }
            return kind.map { .init(id: device.keyID, name: device.label, kind: $0) }
        }
        return DevicesSnapshot(devices: devices, computers: members.machines.map { .init(id: $0.machineID, name: $0.label) },
                               thisDeviceID: thisDeviceID) { CredentialSealing.pairedMac($0, in: members) }
    }

    func publish() {
        snapshotRevision &+= 1
        let next = snapshot
        for continuation in subscribers.values { continuation.yield(next) }
    }
}
