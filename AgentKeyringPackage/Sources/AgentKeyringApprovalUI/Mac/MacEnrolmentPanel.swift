// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// A machine or iPhone asking to join (RFC 0005, RFC 0007 U4). Josh compares
// the code here with the one on the new device, all eight groups, then
// approves with Touch ID. Shown in the same floating panel as requests.

#if os(macOS)
import Observation
import LocalAuthentication
import SwiftUI

@MainActor
public protocol MacEnrolmentBackend: AnyObject {
    /// The enrolment now, then each change; nil once it is no longer waiting
    /// (answered elsewhere, withdrawn or replaced by a new comparison).
    func updates(enrolmentID: String) -> AsyncStream<DeviceEnrolment?>
    /// Josh said the codes match. `comparedCode` is the code he compared,
    /// as shown; Touch ID is the confirmation.
    func approve(enrolmentID: String, comparedCode: String, allowAutomatic: Bool, context: LAContext?,
        onAuthenticated: @MainActor () -> Void, onCommitted: @MainActor () -> Void) async throws
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
    public var allowAutomatic = false {
        didSet { if allowAutomatic != oldValue { restartAuthentication() } }
    }
    public private(set) var isSending = false
    public private(set) var outcome: Outcome?
    public private(set) var failure: String?
    public private(set) var phoneComparisonConfirmed = false
    public var close: () -> Void = {}

    private let backend: any MacEnrolmentBackend
    private let contextFactory: @MainActor () -> LAContext?
    public private(set) var authenticationContext: LAContext?
    private var authenticationTask: Task<Void, Never>?
    private var previousAuthentication: Task<Void, Never>?
    private var authenticationTimeout: Task<Void, Never>?
    var authenticationTimeoutDuration: Duration = .seconds(60)
    private var authenticationID = UUID()

    public init(enrolment: DeviceEnrolment, backend: any MacEnrolmentBackend,
        contextFactory: @escaping @MainActor () -> LAContext? = { MacEnrolmentModel.makeContext() }) {
        self.enrolment = enrolment
        self.backend = backend
        self.contextFactory = contextFactory
        if enrolment.kind == .machine {
            authenticationContext = contextFactory()
            if authenticationContext == nil { failure = "Touch ID or Apple Watch isn't available. Check that one is ready." }
        }
    }

    /// Follows the enrolment until the panel closes. Call from `.task`.
    public func followUpdates() async {
        for await latest in backend.updates(enrolmentID: enrolment.id) {
            guard outcome == nil, !isSending else { continue }
            if let latest { enrolment = latest }
            else { stopAuthentication(); outcome = .gone }
        }
    }

    public func approve() async {
        guard enrolment.kind == .approver else { return }
        phoneComparisonConfirmed = true
        restartAuthentication()
    }

    public static func makeContext() -> LAContext? {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometricsOrCompanion, error: nil) ? context : nil
    }

    public func restartAuthentication() {
        stopAuthentication()
        guard (enrolment.kind == .machine || phoneComparisonConfirmed), outcome == nil else { return }
        failure = nil
        authenticationContext = contextFactory()
        if authenticationContext == nil { failure = "Touch ID or Apple Watch isn't available. Check that one is ready." }
    }

    public func stopAuthentication() {
        authenticationID = UUID()
        if let authenticationTask { previousAuthentication = authenticationTask }
        authenticationTask?.cancel()
        authenticationTask = nil
        authenticationTimeout?.cancel()
        authenticationTimeout = nil
        authenticationContext?.invalidate()
        authenticationContext = nil
    }

    public func waitForAuthentication() {
        guard let context = authenticationContext, authenticationTask == nil, outcome == nil else { return }
        let id = authenticationID
        let automatic = allowAutomatic
        let previous = previousAuthentication
        previousAuthentication = nil
        authenticationTimeout = Task {
            do { try await Task.sleep(for: authenticationTimeoutDuration) } catch { return }
            guard authenticationID == id, outcome == nil else { return }
            stopAuthentication()
            failure = "Approval timed out."
        }
        authenticationTask = Task {
            await previous?.value
            guard !Task.isCancelled, authenticationID == id else { return }
            do {
                try await backend.approve(enrolmentID: enrolment.id, comparedCode: enrolment.code,
                    allowAutomatic: automatic, context: context, onAuthenticated: {
                        self.authenticationTimeout?.cancel()
                        self.authenticationTimeout = nil
                    }, onCommitted: { self.outcome = .joined })
                guard !Task.isCancelled, authenticationID == id else { return }
                outcome = .joined
            } catch {
                guard !Task.isCancelled, authenticationID == id else { return }
                failure = ownerAuthenticationFailure(error, fallback: SetupCopy.joiningFailed)
                authenticationContext = nil
            }
            if authenticationID == id { authenticationTask = nil; authenticationTimeout?.cancel(); authenticationTimeout = nil }
        }
    }

    public func refuse() async {
        stopAuthentication()
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
                Text(SetupCopy.joiningLead(model.enrolment))
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

            // A machine's code is checked by the agent setting it up; only an
            // iPhone, whose screen Josh holds, is compared by eye.
            if model.enrolment.kind == .approver {
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
        .onDisappear { model.stopAuthentication() }
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
            let isPhone = model.enrolment.kind == .approver
            HStack(spacing: 10) {
                Button(isPhone ? SetupCopy.doesNotMatch : SetupCopy.dontAllow) { Task { await model.refuse() } }
                    .buttonStyle(DecisionButtonStyle(colour: KeyringColour.deny, height: 36))
                if isPhone && !model.phoneComparisonConfirmed {
                    Button { Task { await model.approve() } } label: {
                        if model.isSending { ProgressView().controlSize(.small).tint(.white) }
                        else { Label(SetupCopy.theyMatch, systemImage: "touchid") }
                    }
                    .buttonStyle(DecisionButtonStyle(colour: KeyringColour.approve, height: 36))
                } else if let context = model.authenticationContext {
                    EmbeddedOwnerApproval(context: context, action: isPhone ? "pair your iPhone" : "approve")
                        .id(ObjectIdentifier(context))
                        .onAppear { model.waitForAuthentication() }
                } else {
                    Button("Try again") { model.restartAuthentication() }
                        .buttonStyle(DecisionButtonStyle(colour: KeyringColour.approve, height: 36))
                }
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
