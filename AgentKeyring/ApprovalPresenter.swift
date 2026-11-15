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

        var isRequest: Bool {
            if case .joining = self { return false }
            if case .relay = self { return false }
            return true
        }
    }

    private let model: MirrorAppModel
    private let localBackend: LeaseApprovalBackend
    private let remoteBackend: RelayApprovalBackend
    private let joiningBackend: RelayEnrolmentBackend
    private let panel = MacApprovalPanelController()
    private var relayPanel: NSPanel?
    private var shownItem: Item?
    private var shownRequest: MacApprovalModel?
    private var shownEnrolment: MacEnrolmentModel?
    private var relayApproval: RelayConnectionApproval?
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
        let relaySetup: [Item] = relay.pairing.map { $0.answerIsQueued ? [] : [.relay] } ?? []
        let local = model.leaseStore.waitingRequests.map { (Item.local($0.leaseID), $0.requestedAtUnixSeconds) }
        let remote = relay.requests.filter { $0.lease.state == .pending && !$0.answerIsQueued }
            .map { (Item.remote($0.id), $0.record.createdUnixSeconds) }
        return relaySetup + joining + (local + remote).sorted { $0.1 < $1.1 }.map(\.0)
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
        shownEnrolment?.stopAuthentication()
        shownEnrolment = nil
        relayApproval?.stop()
        relayApproval = nil
        panel.close()
        relayPanel?.orderOut(nil)
        relayPanel = nil
        closingAfterAnswer?.cancel()
        closingAfterAnswer = nil
        let more = waiting.filter { $0 != item && $0.isRequest }.count
        switch item {
        case .relay:
            showRelayPrompt()
            shownRequest = nil
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
            shownEnrolment = joining
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
        shownEnrolment?.stopAuthentication()
        shownEnrolment = nil
        relayApproval?.stop()
        relayApproval = nil
        closingAfterAnswer?.cancel()
        closingAfterAnswer = nil
        panel.close()
        relayPanel?.orderOut(nil)
        relayPanel = nil
        shownItem = nil
        shownRequest = nil
        if let next = waiting.first { show(next) }
    }

    private func showRelayPrompt() {
        let relay = model.relayApprover
        let approval = RelayConnectionApproval()
        relayApproval = approval
        let content = RelayConnectionPrompt(approval: approval, confirm: { context in
            try await relay.confirmPairing(comparedFingerprint: "", context: context) { approval.cancelTimeout() }
        }, cancel: {
            try relay.abandonPairing()
        }, done: { [weak self] in self?.dismiss() })
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        let window = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        window.contentViewController = controller
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.setContentSize(controller.view.fittingSize)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: visible.maxX - window.frame.width - 12, y: visible.maxY - 8))
        }
        relayPanel = window
        window.orderFrontRegardless()
    }
}

@MainActor @Observable
private final class RelayConnectionApproval {
    var context: LAContext? = makeContext()
    var task: Task<Void, Never>?
    var previous: Task<Void, Never>?
    var timeout: Task<Void, Never>?
    var id = UUID()
    var failure: String?

    init() {
        if context == nil { failure = "Touch ID or Apple Watch isn't available. Check that one is ready and try again." }
    }

    private static func makeContext() -> LAContext? {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometricsOrCompanion, error: nil) ? context : nil
    }

    func stop() {
        id = UUID()
        if let task { previous = task }
        task?.cancel()
        task = nil
        timeout?.cancel()
        timeout = nil
        context?.invalidate()
        context = nil
    }

    func retry() {
        stop()
        failure = nil
        context = Self.makeContext()
        if context == nil { failure = "Touch ID or Apple Watch isn't available. Check that one is ready and try again." }
    }

    func cancelTimeout() {
        timeout?.cancel()
        timeout = nil
    }

    func wait(context: LAContext, confirm: @escaping @MainActor (LAContext) async throws -> Void,
        done: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        let currentID = id
        let previous = previous
        self.previous = nil
        timeout = Task {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard id == currentID else { return }
            stop()
            failure = "Approval timed out. Try again."
        }
        task = Task {
            await previous?.value
            guard !Task.isCancelled, id == currentID else { return }
            do {
                try await confirm(context)
                guard !Task.isCancelled, id == currentID else { return }
                done()
            } catch {
                guard !Task.isCancelled, id == currentID else { return }
                failure = ownerAuthenticationFailure(error, fallback: "Couldn't connect. Try again.")
                self.context = nil
            }
            if id == currentID { task = nil; timeout?.cancel(); timeout = nil }
        }
    }
}

private struct RelayConnectionPrompt: View {
    @Bindable var approval: RelayConnectionApproval
    let confirm: @MainActor (LAContext) async throws -> Void
    let cancel: @MainActor () throws -> Void
    let done: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect this Mac to your Mac mini?").font(.headline)
            Text("Agents on your other machines can then ask you for logins. Their requests go through your Mac mini.")
                .font(.callout).foregroundStyle(.secondary)
            if let failure = approval.failure { Text(failure).font(.callout).foregroundStyle(KeyringColour.denyText) }
            HStack(spacing: 10) {
                Button("Not now") {
                    approval.stop()
                    do { try cancel(); done() }
                    catch { approval.failure = (error as? LocalizedError)?.errorDescription ?? "Couldn't cancel. Try again." }
                }
                .buttonStyle(DecisionButtonStyle(colour: KeyringColour.deny, height: 36))
                if let context = approval.context {
                    EmbeddedOwnerApproval(context: context)
                        .id(ObjectIdentifier(context))
                        .onAppear { approval.wait(context: context, confirm: confirm, done: done) }
                } else {
                    Button("Try again") { approval.retry() }
                        .buttonStyle(DecisionButtonStyle(colour: KeyringColour.approve, height: 36))
                }
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(KeyringColour.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onDisappear { approval.stop() }
    }
}
