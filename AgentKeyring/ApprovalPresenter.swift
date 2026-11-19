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

    private let model: MirrorAppModel
    private let localBackend: LeaseApprovalBackend
    private let remoteBackend: RelayApprovalBackend
    private let additionBackend: AdditionBackend
    private let selfTestBackend: SelfTestBackend
    private let panel = MacApprovalPanelController()
    private var shownItem: Item?
    private var shownRequest: MacApprovalModel?
    private var question: OwnerApproval?
    private var following: Task<Void, Never>?
    private var closingAfterAnswer: Task<Void, Never>?
    /// The practice request waits until Touch ID has a fingerprint; first run says why.
    private var needsFingerprint = MacApprover.needsFingerprint
    /// The item `show` is putting up, for `showRequest`.
    private var showing: Item?
    private var observers: [NSObjectProtocol] = []

    init(model: MirrorAppModel) {
        self.model = model
        self.localBackend = LeaseApprovalBackend(model: model)
        self.remoteBackend = RelayApprovalBackend(model: model)
        self.additionBackend = AdditionBackend(model: model)
        self.selfTestBackend = SelfTestBackend(model: model)
    }

    /// Takes over Mac approvals from the system prompt and follows both stores.
    func start() {
        let observations = Observations { [weak self] in self?.waiting ?? [] }
        following = Task { [weak self] in
            for await items in observations { self?.update(items) }
        }
        for name in [NSApplication.didChangeScreenParametersNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.approverChanged() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
            queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.approverChanged() } })
    }

    /// The lid opened or closed, or a fingerprint may have been added.
    private func approverChanged() {
        needsFingerprint = MacApprover.needsFingerprint
        if let shownRequest, let shownItem { configure(shownRequest, for: shownItem) }
        update(waiting)
    }

    /// With the lid shut the panel says where the request can still be
    /// answered. Agents' requests, from this Mac or another computer, reach the
    /// iPhone and Apple Watch through the relay; this Mac's own only while the
    /// relay can be reached, since this Mac never waits for it.
    private func configure(_ approval: MacApprovalModel, for item: Item) {
        approval.lidClosed = MacApprover.lidIsClosed
        let phoneOrWatch = model.device?.members?.devices.contains { $0.kind == .iphone || $0.kind == .watch } == true
        switch item {
        case .remote: approval.approvesElsewhere = phoneOrWatch
        case .local: approval.approvesElsewhere = phoneOrWatch && model.device?.connection == .connected
        default: approval.approvesElsewhere = false
        }
    }

    /// Brings a waiting request forward, from the menu bar's Review.
    func present(requestID: String) {
        if let item = waiting.first(where: { $0 == .local(requestID) || $0 == .remote(requestID) }) { show(item) }
    }

    /// Brings a joining device forward, from the menu bar or Machines window.
    func present(enrolmentID: String) {
        if waiting.contains(.joining(enrolmentID)) { show(.joining(enrolmentID)) }
    }

    private var waiting: [Item] {
        let device = model.device
        let joining = device?.joins.map { Item.joining(MacDevice.joinID($0)) } ?? []
        let relaySetup: [Item] = device?.setup?.machine == nil ? [] : [.relay]
        let local = model.leaseStore.waitingRequests.map { (Item.local($0.leaseID), $0.requestedAtUnixSeconds) }
        let remote = (device?.waitingRequests ?? []).map { (Item.remote($0.requestID), $0.askedUnixSeconds) }
        let sendImported: [Item] = model.importedLoginsAwaitApproval ? [.sendImported] : []
        let selfTest: [Item] = model.selfTest == .waiting && !needsFingerprint ? [.selfTest] : []
        return selfTest + relaySetup + joining + sendImported + (local + remote).sorted { $0.1 < $1.1 }.map(\.0)
    }

    private func update(_ items: [Item]) {
        guard let shownItem else {
            if let next = items.first { show(next) }
            return
        }
        shownRequest?.moreWaiting = items.filter { $0 != shownItem && $0.isRequest }.count
        // Answered, withdrawn or timed out: show the outcome briefly, then move on.
        if !items.contains(shownItem), closingAfterAnswer == nil {
            // A denial stays up long enough to take back with "Let it ask again".
            let linger: Duration = shownRequest?.isHoldingOff == true ? .seconds(10) : .seconds(2.5)
            closingAfterAnswer = Task { [weak self] in
                try? await Task.sleep(for: linger)
                guard !Task.isCancelled else { return }
                self?.dismiss()
            }
        }
    }

    private func show(_ item: Item) {
        // One approval at a time: a panel being replaced stops waiting for a touch.
        shownRequest?.cancelApproval()
        question?.invalidate()
        question = nil
        panel.close()
        closingAfterAnswer?.cancel()
        closingAfterAnswer = nil
        let more = waiting.filter { $0 != item && $0.isRequest }.count
        showing = item
        switch item {
        case .relay:
            guard let request = additionBackend.request(AdditionBackend.setupID) else { return }
            showRequest(MacApprovalModel(request: request, moreWaiting: more, backend: additionBackend))
        case .sendImported:
            let model = model
            ask(SetupCopy.sendImportedTitle, SetupCopy.sendImportedBody,
                reason: SetupCopy.sendImportedReason,
                perform: { context in try await model.sendImportedLogins(context: context) },
                declined: { model.declineSendingImportedLogins() })
        case .selfTest:
            showRequest(MacApprovalModel(request: selfTestBackend.request, moreWaiting: more, backend: selfTestBackend))
        case let .local(id):
            guard let lease = model.leaseStore.waitingRequests.first(where: { $0.leaseID == id }) else { return }
            showRequest(MacApprovalModel(request: model.accessRequest(for: lease), moreWaiting: more, backend: localBackend))
        case let .remote(id):
            guard let request = remoteBackend.current(id) else { return }
            showRequest(MacApprovalModel(request: request, moreWaiting: more, backend: remoteBackend))
        case let .joining(id):
            guard let request = additionBackend.request(id) else { return }
            showRequest(MacApprovalModel(request: request, moreWaiting: more, backend: additionBackend))
        }
        shownItem = item
    }

    private func showRequest(_ approval: MacApprovalModel) {
        if let showing { configure(approval, for: showing) }
        panel.show(approval)
        approval.close = { [weak self] in self?.dismiss() }
        shownRequest = approval
    }

    private func dismiss() {
        shownRequest?.cancelApproval()
        question?.invalidate()
        question = nil
        closingAfterAnswer?.cancel()
        closingAfterAnswer = nil
        panel.close()
        shownItem = nil
        shownRequest = nil
        if let next = waiting.first { show(next) }
    }

    /// A yes-or-no question beside Josh's window, approved in place.
    private func ask(_ title: String, _ message: String, reason: String,
        perform: @escaping @MainActor (LAContext) async throws -> Void, declined: @escaping @MainActor () -> Void) {
        let approval = OwnerApproval(action: SetupCopy.allow.lowercased(), reason: reason, perform: perform) { [weak self] approved in
            if !approved { declined() }
            self?.dismiss()
        }
        question = approval
        shownRequest = nil
        panel.show(question: title, message: message, approval: approval)
    }
}
