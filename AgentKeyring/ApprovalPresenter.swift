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
import Foundation
import Observation

@MainActor
final class ApprovalPresenter {
    private enum Item: Hashable {
        case local(String)
        case remote(String)
        case joining(String)

        var isRequest: Bool {
            if case .joining = self { return false }
            return true
        }
    }

    private let model: MirrorAppModel
    private let localBackend: LeaseApprovalBackend
    private let remoteBackend: RelayApprovalBackend
    private let joiningBackend: RelayEnrolmentBackend
    private let panel = MacApprovalPanelController()
    private var shownItem: Item?
    private var shownRequest: MacApprovalModel?
    private var following: Task<Void, Never>?
    private var closingAfterAnswer: Task<Void, Never>?

    init(model: MirrorAppModel) {
        self.model = model
        self.localBackend = LeaseApprovalBackend(model: model)
        self.remoteBackend = RelayApprovalBackend(relay: model.relayApprover)
        self.joiningBackend = RelayEnrolmentBackend(relay: model.relayApprover)
    }

    /// Takes over Mac approvals from the system prompt and follows both stores.
    func start() {
        model.automaticallyPromptForLeases = false
        let observations = Observations { [weak self] in self?.waiting ?? [] }
        following = Task { [weak self] in
            for await items in observations { self?.update(items) }
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
        let relay = model.relayApprover
        let joining = relay.pendingEnrolments.map { Item.joining($0.id) }
            + relay.pendingApproverPairings.map { Item.joining($0.id) }
        let local = model.leaseStore.waitingRequests.map { (Item.local($0.leaseID), $0.requestedAtUnixSeconds) }
        let remote = relay.requests.filter { $0.lease.state == .pending && !$0.answerIsQueued }
            .map { (Item.remote($0.id), $0.record.createdUnixSeconds) }
        return joining + (local + remote).sorted { $0.1 < $1.1 }.map(\.0)
    }

    private func update(_ items: [Item]) {
        guard let shownItem else {
            if let next = items.first { show(next) }
            return
        }
        shownRequest?.moreWaiting = items.filter { $0 != shownItem && $0.isRequest }.count
        // Answered, withdrawn or timed out: show the outcome briefly, then move on.
        if !items.contains(shownItem), closingAfterAnswer == nil {
            closingAfterAnswer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                self?.dismiss()
            }
        }
    }

    private func show(_ item: Item) {
        // One approval at a time: a panel being replaced stops waiting for a touch.
        shownRequest?.stopWaitingForTouch()
        closingAfterAnswer?.cancel()
        closingAfterAnswer = nil
        let more = waiting.filter { $0 != item && $0.isRequest }.count
        switch item {
        case let .local(id):
            guard let lease = model.leaseStore.waitingRequests.first(where: { $0.leaseID == id }) else { return }
            showRequest(MacApprovalModel(request: model.accessRequest(for: lease), moreWaiting: more, backend: localBackend))
        case let .remote(id):
            guard let request = remoteBackend.current(id) else { return }
            showRequest(MacApprovalModel(request: request, moreWaiting: more, backend: remoteBackend))
        case let .joining(id):
            guard let enrolment = joiningBackend.current(id) else { return }
            let joining = MacEnrolmentModel(enrolment: enrolment, backend: joiningBackend)
            panel.show(joining)
            joining.close = { [weak self] in self?.dismiss() }
            shownRequest = nil
        }
        shownItem = item
    }

    private func showRequest(_ approval: MacApprovalModel) {
        panel.show(approval)
        approval.close = { [weak self] in self?.dismiss() }
        shownRequest = approval
    }

    private func dismiss() {
        shownRequest?.stopWaitingForTouch()
        closingAfterAnswer?.cancel()
        closingAfterAnswer = nil
        panel.close()
        shownItem = nil
        shownRequest = nil
        if let next = waiting.first { show(next) }
    }
}
