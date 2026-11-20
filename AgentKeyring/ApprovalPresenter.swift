// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Shows the floating panel for everything that waits for Josh, one at a
// time (RFC 0007 U2 and U4): devices joining first, because someone is at
// the other device comparing a code, then requests from this Mac and from
// the relay, oldest first. Replaces the transitional system Touch ID prompt.

import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringProtocol
import AgentKeyringScreenBackends
import AppKit
import Foundation
import LocalAuthentication
import Observation
import SwiftUI

@MainActor
final class ApprovalPresenter {
    private enum Item: Hashable {
        case local(String)
        case remote(String)
        case joining(String)
        case relay
        case sendImported
        case selfTest

        var isRequest: Bool {
            switch self {
            case .local, .remote: true
            case .joining, .relay, .sendImported, .selfTest: false
            }
        }
    }

    /// What is on screen: one panel at a time, and nothing else to disagree with it.
    private enum Presented {
        case idle
        case showing(Item, Shown)
        /// Answered, withdrawn or timed out: the outcome stays briefly, then the next.
        case closing(Item, Shown, Task<Void, Never>)

        var item: Item? {
            switch self {
            case .idle: nil
            case let .showing(item, _), let .closing(item, _, _): item
            }
        }

        var request: MacApprovalModel? {
            switch self {
            case let .showing(_, .request(model)), let .closing(_, .request(model), _): model
            default: nil
            }
        }
    }

    private enum Shown {
        case request(MacApprovalModel)
        case question(OwnerApproval)
    }

    private let model: MirrorAppModel
    private let localBackend: LeaseApprovalBackend
    private let remoteBackend: RelayApprovalBackend
    private let additionBackend: AdditionBackend
    private let selfTestBackend: SelfTestBackend
    private let panel = MacApprovalPanelController()
    private var presented = Presented.idle
    private var following: Task<Void, Never>?

    init(model: MirrorAppModel) {
        self.model = model
        self.localBackend = LeaseApprovalBackend(model: model)
        self.remoteBackend = RelayApprovalBackend(model: model)
        self.additionBackend = AdditionBackend(model: model)
        self.selfTestBackend = SelfTestBackend(model: model)
    }

    /// Follows everything that waits for Josh, and the lid and Touch ID through `waiting`.
    func start() {
        MacApprover.shared.follow()
        let observations = Observations { [weak self] in self?.waiting ?? [] }
        following = Task { [weak self] in
            for await items in observations { self?.update(items) }
        }
    }

    /// With the lid shut the panel says where the request can still be
    /// answered. Agents' requests, from this Mac or another computer, reach the
    /// iPhone and Apple Watch through the relay; this Mac's own only while the
    /// relay can be reached, since this Mac never waits for it.
    private func approvesElsewhere(_ item: Item) -> Bool {
        let phoneOrWatch = model.device?.members?.devices.contains { $0.kind == .iphone || $0.kind == .watch } == true
        switch item {
        case .remote: return phoneOrWatch
        case .local: return phoneOrWatch && model.device?.connection == .connected
        default: return false
        }
    }

    /// Brings a waiting request forward, from the menu bar's Review.
    func present(requestID: String) {
        if let item = waiting.first(where: { $0 == .local(requestID) || $0 == .remote(requestID) }) { show(first: [item]) }
    }

    /// Brings a joining device forward, from the menu bar or Machines window.
    func present(enrolmentID: String) {
        if waiting.contains(.joining(enrolmentID)) { show(first: [.joining(enrolmentID)]) }
    }

    private var waiting: [Item] {
        let device = model.device
        let joining = device?.joins.map { Item.joining(MacDevice.joinID($0)) } ?? []
        let relaySetup: [Item] = device?.setup?.machine == nil ? [] : [.relay]
        let local = model.leaseStore.waitingRequests.map { (Item.local($0.leaseID), $0.requestedAtUnixSeconds) }
        let remote = (device?.waitingRequests ?? []).map { (Item.remote($0.requestID), $0.askedUnixSeconds) }
        let sendImported: [Item] = model.importedLoginsAwaitApproval ? [.sendImported] : []
        // The window says "Open the lid" or "Add a fingerprint" in its place.
        let selfTest: [Item] = (model.firstRun == .practice || model.practiceWaitingHere) && MacApprover.shared.state == .ready ? [.selfTest] : []
        return selfTest + relaySetup + joining + sendImported + (local + remote).sorted { $0.1 < $1.1 }.map(\.0)
    }

    private func update(_ items: [Item]) {
        switch presented {
        case .idle:
            show(first: items)
        case let .showing(item, shown):
            presented.request?.moreWaiting = items.filter { $0 != item && $0.isRequest }.count
            guard !items.contains(item) else { return }
            // A denial stays up long enough to take back with "Let it ask again";
            // the practice request goes at once, as first run's window says what happened.
            let linger: Duration = item == .selfTest ? .zero : presented.request?.isHoldingOff == true ? .seconds(10) : .seconds(2.5)
            presented = .closing(item, shown, Task { [weak self] in
                try? await Task.sleep(for: linger)
                guard !Task.isCancelled else { return }
                self?.dismiss()
            })
        case .closing:
            break
        }
    }

    /// Puts up the first of `items` that can still be shown; one approval at a
    /// time, so whatever was up stops waiting for a touch first.
    private func show(first items: [Item]) {
        takeDown()
        for item in items {
            guard let shown = make(item) else { continue }
            switch shown {
            case let .request(approval):
                approval.approvesElsewhere = approvesElsewhere(item)
                panel.show(approval)
                approval.close = { [weak self] in self?.dismiss() }
            case let .question(approval):
                panel.show(question: SetupCopy.sendImportedTitle, message: SetupCopy.sendImportedBody, approval: approval)
            }
            presented = .showing(item, shown)
            DiagnosticLog.record("panel", "shown", ["item": "\(item)"])
            return
        }
    }

    private func make(_ item: Item) -> Shown? {
        let more = waiting.filter { $0 != item && $0.isRequest }.count
        func request(_ request: AccessRequest?, _ backend: any MacApprovalBackend) -> Shown? {
            request.map { .request(MacApprovalModel(request: $0, moreWaiting: more, backend: backend)) }
        }
        switch item {
        case .relay: return request(additionBackend.request(AdditionBackend.setupID), additionBackend)
        case .selfTest: return request(selfTestBackend.request, selfTestBackend)
        case let .local(id):
            return request(model.leaseStore.waitingRequests.first { $0.leaseID == id }.map(model.accessRequest(for:)), localBackend)
        case let .remote(id): return request(remoteBackend.current(id), remoteBackend)
        case let .joining(id): return request(additionBackend.request(id), additionBackend)
        case .sendImported:
            let model = model
            return .question(ask(reason: SetupCopy.sendImportedReason,
                perform: { context in try await model.sendImportedLogins(context: context) },
                declined: { model.declineSendingImportedLogins() }))
        }
    }

    private func takeDown() {
        switch presented {
        case .idle: break
        case let .showing(_, shown): stop(shown)
        case let .closing(_, shown, linger): linger.cancel(); stop(shown)
        }
        panel.close()
        presented = .idle
    }

    private func stop(_ shown: Shown) {
        switch shown {
        case let .request(approval): approval.cancelApproval()
        case let .question(approval): approval.invalidate()
        }
    }

    private func dismiss() {
        show(first: waiting)
    }

    /// A yes-or-no question beside Josh's window, approved in place.
    private func ask(reason: String, perform: @escaping @MainActor (LAContext) async throws -> Void,
        declined: @escaping @MainActor () -> Void) -> OwnerApproval {
        OwnerApproval(action: SetupCopy.allow.lowercased(), reason: reason, perform: perform) { [weak self] approved in
            if !approved { declined() }
            self?.dismiss()
        }
    }
}
