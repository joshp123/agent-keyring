// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// A machine or iPhone asking to join (RFC 0005, RFC 0007 U4). Josh compares
// the code here with the one on the new device, all eight groups, then
// approves with Touch ID. Shown in the same floating panel as requests.

#if os(macOS)
import Observation
import SwiftUI

@MainActor
public protocol MacEnrolmentBackend: AnyObject {
    /// The enrolment now, then each change; nil once it is no longer waiting
    /// (answered elsewhere, withdrawn or replaced by a new comparison).
    func updates(enrolmentID: String) -> AsyncStream<DeviceEnrolment?>
    /// Josh said the codes match. `comparedCode` is the code he compared,
    /// as shown; Touch ID is the confirmation.
    func approve(enrolmentID: String, comparedCode: String, allowAutomatic: Bool) async throws
    func refuse(enrolmentID: String) async throws
}

@MainActor
@Observable
public final class MacEnrolmentModel {
    public enum Outcome: Hashable, Sendable {
        case joined
        case refused
        /// Gone before Josh answered: withdrawn, or replaced by a new code.
        case gone
    }

    public private(set) var enrolment: DeviceEnrolment
    public var allowAutomatic = false
    public private(set) var isSending = false
    public private(set) var outcome: Outcome?
    public private(set) var failure: String?
    public var close: () -> Void = {}

    private let backend: any MacEnrolmentBackend

    public init(enrolment: DeviceEnrolment, backend: any MacEnrolmentBackend) {
        self.enrolment = enrolment
        self.backend = backend
    }

    /// Follows the enrolment until the panel closes. Call from `.task`.
    public func followUpdates() async {
        for await latest in backend.updates(enrolmentID: enrolment.id) {
            guard outcome == nil, !isSending else { continue }
            if let latest { enrolment = latest } else { outcome = .gone }
        }
    }

    public func approve() async {
        await send(.joined) {
            try await backend.approve(enrolmentID: enrolment.id, comparedCode: enrolment.code,
                allowAutomatic: allowAutomatic && enrolment.kind == .machine)
        }
    }

    public func refuse() async {
        await send(.refused) { try await backend.refuse(enrolmentID: enrolment.id) }
    }

    private func send(_ result: Outcome, action: () async throws -> Void) async {
        isSending = true
        failure = nil
        defer { isSending = false }
        do {
            try await action()
            outcome = result
        } catch {
            failure = (error as? LocalizedError)?.errorDescription
                ?? (result == .joined ? SetupCopy.joiningFailed : "That didn't go through. Try again.")
        }
    }
}

public struct MacEnrolmentPanelView: View {
    @Bindable var model: MacEnrolmentModel

    public init(model: MacEnrolmentModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: model.enrolment.kind == .machine ? "desktopcomputer" : "iphone")
                    .foregroundStyle(KeyringColour.signal)
                Text("Agent Keyring")
                    .font(.subheadline.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(SetupCopy.joiningLead(model.enrolment.kind))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(model.enrolment.name)
                    .font(.title.weight(.bold))
                    .tracking(-0.6)
                if !model.enrolment.tailnetNode.isEmpty {
                    Text(SetupCopy.tailnetNode(model.enrolment.tailnetNode))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                if let old = model.enrolment.replacesPhone {
                    Text(SetupCopy.replacesPhone(old))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(SetupCopy.compareWith(model.enrolment))
                    .font(.subheadline.weight(.semibold))
                FingerprintGrid(model.enrolment.code)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                Text(SetupCopy.allGroupsMustMatch)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if model.enrolment.kind == .machine && model.outcome == nil {
                Divider()
                Toggle(isOn: $model.allowAutomatic) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SetupCopy.allowAutomatic)
                        if !model.allowAutomatic {
                            Text(SetupCopy.allowAutomaticOff)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.switch)
            }

            Divider()
            answers
            if let failure = model.failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(KeyringColour.denyText)
            }
        }
        .padding(18)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.followUpdates() }
    }

    @ViewBuilder private var answers: some View {
        if let outcome = model.outcome {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: outcome == .joined ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(outcome == .joined ? KeyringColour.approveText : KeyringColour.denyText)
                Text(outcomeText(outcome))
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Close", action: model.close)
                .buttonStyle(.quiet(height: 32))
        } else {
            HStack(spacing: 10) {
                Button(SetupCopy.doesNotMatch) { Task { await model.refuse() } }
                    .buttonStyle(DecisionButtonStyle(colour: KeyringColour.deny, height: 36))
                Button { Task { await model.approve() } } label: {
                    if model.isSending { ProgressView().controlSize(.small).tint(.white) }
                    else { Label(SetupCopy.theyMatch, systemImage: "touchid") }
                }
                .buttonStyle(DecisionButtonStyle(colour: KeyringColour.approve, height: 36))
            }
            .disabled(model.isSending)
        }
    }

    private func outcomeText(_ outcome: MacEnrolmentModel.Outcome) -> String {
        switch outcome {
        case .joined: SetupCopy.joined(model.enrolment)
        case .refused: SetupCopy.refused(model.enrolment)
        case .gone: "\(model.enrolment.name) stopped asking, or started again with a new code."
        }
    }
}

extension MacApprovalPanelController {
    /// Shows a joining device in the same panel requests use.
    public func show(_ model: MacEnrolmentModel) {
        showPanel(MacEnrolmentPanelView(model: model))
        model.close = { [weak self] in self?.close() }
    }
}
#endif
