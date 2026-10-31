// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Shows the approval panel for each request that waits for Josh (RFC 0007,
// U2), oldest first, in place of the transitional system Touch ID prompt.

import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringProtocol
import AgentKeyringScreenBackends
import Foundation

@MainActor
final class LeaseApprovalPresenter {
    private let model: MirrorAppModel
    private let backend: LeaseApprovalBackend
    private let panel = MacApprovalPanelController()
    private var shown: MacApprovalModel?
    private var following: Task<Void, Never>?
    private var closingAfterAnswer: Task<Void, Never>?

    init(model: MirrorAppModel) {
        self.model = model
        self.backend = LeaseApprovalBackend(model: model)
    }

    /// Takes over Mac approvals from the system prompt and follows the store.
    func start() {
        model.automaticallyPromptForLeases = false
        following = Task { [weak self, leaseStore = model.leaseStore] in
            for await leases in leaseStore.changes() {
                self?.update(leases)
            }
        }
    }

    /// Brings one waiting request forward, from the menu bar's Review.
    func present(leaseID: String) {
        guard let lease = model.leaseStore.waitingRequests.first(where: { $0.leaseID == leaseID }) else { return }
        show(lease)
    }

    private var waiting: [Agentkeyring_V1_Lease] {
        model.leaseStore.waitingRequests.sorted { $0.requestedAtUnixSeconds < $1.requestedAtUnixSeconds }
    }

    private func update(_ leases: [Agentkeyring_V1_Lease]) {
        if let shown {
            shown.moreWaiting = waiting.filter { $0.leaseID != shown.request.id }.count
            let stillWaiting = leases.contains { $0.leaseID == shown.request.id && $0.state == .pending }
            // Answered here, withdrawn or timed out: show the outcome briefly,
            // then move on to the next waiting request.
            if !stillWaiting, closingAfterAnswer == nil {
                closingAfterAnswer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled else { return }
                    self?.dismiss()
                }
            }
            return
        }
        if let next = waiting.first { show(next) }
    }

    private func show(_ lease: Agentkeyring_V1_Lease) {
        // One approval at a time: a panel being replaced stops waiting for a touch.
        shown?.stopWaitingForTouch()
        closingAfterAnswer?.cancel()
        closingAfterAnswer = nil
        let approval = MacApprovalModel(request: model.accessRequest(for: lease),
            moreWaiting: waiting.filter { $0.leaseID != lease.leaseID }.count, backend: backend)
        panel.show(approval)
        approval.close = { [weak self] in self?.dismiss() }
        shown = approval
    }

    private func dismiss() {
        shown?.stopWaitingForTouch()
        closingAfterAnswer?.cancel()
        closingAfterAnswer = nil
        panel.close()
        shown = nil
        if let next = waiting.first { show(next) }
    }
}
