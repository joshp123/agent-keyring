// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The Machines window (RFC 0007 U4): the Mac's link to the relay, set up
// once by comparing a code, machines waiting to join, and machines that can
// ask, each removable. Opened from the menu bar.

#if os(macOS)
import Observation
import SwiftUI

public enum RelayLink: Hashable, Sendable {
    case notSetUp
    case connecting(address: String)
    /// First setup: the code this Mac computed, to compare with the relay's
    /// code that setup brings over SSH.
    case comparing(code: String, address: String)
    case connected(address: String)
    case offline(address: String)
}

public struct EnrolledMachine: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var tailnetNode: String
    public var automaticAllowed: Bool

    public init(id: String, name: String, tailnetNode: String, automaticAllowed: Bool) {
        self.id = id
        self.name = name
        self.tailnetNode = tailnetNode
        self.automaticAllowed = automaticAllowed
    }
}

/// A device in the current approver key set.
public struct ApproverDevice: Hashable, Sendable {
    public var keyID: String
    public var name: String
    public var isPhone: Bool

    public init(keyID: String = "", name: String, isPhone: Bool) {
        self.keyID = keyID
        self.name = name
        self.isPhone = isPhone
    }
}

/// A removal or narrowed permission that every remaining device must
/// confirm, with its own signature, before it counts as done.
public struct PendingWithdrawal: Identifiable, Hashable, Sendable {
    public let id: String
    /// For example "Removing Josh's old iPhone".
    public var title: String
    public var confirmedOn: [String]
    public var waitingFor: [String]

    public init(id: String, title: String, confirmedOn: [String], waitingFor: [String]) {
        self.id = id
        self.title = title
        self.confirmedOn = confirmedOn
        self.waitingFor = waitingFor
    }
}

public struct MachinesSnapshot: Hashable, Sendable {
    public var relay: RelayLink
    /// Signed answers saved on this Mac, waiting for the relay.
    public var queuedAnswers: Int
    /// A confirmed change to rules or machines the relay hasn't acknowledged yet.
    public var isApplying: Bool
    public var waiting: [DeviceEnrolment]
    public var machines: [EnrolledMachine]
    public var approvers: [ApproverDevice]
    /// Unfinished only; a withdrawal leaves the list once every device confirms.
    public var withdrawals: [PendingWithdrawal]
    /// How long a request waits here before the Mac asks the iPhone (RFC 0006).
    public var askPhoneAfter: Duration

    public init(relay: RelayLink, queuedAnswers: Int = 0, isApplying: Bool = false,
        waiting: [DeviceEnrolment] = [], machines: [EnrolledMachine] = [], approvers: [ApproverDevice] = [],
        withdrawals: [PendingWithdrawal] = [], askPhoneAfter: Duration = .seconds(120)) {
        self.relay = relay
        self.queuedAnswers = queuedAnswers
        self.isApplying = isApplying
        self.waiting = waiting
        self.machines = machines
        self.approvers = approvers
        self.withdrawals = withdrawals
        self.askPhoneAfter = askPhoneAfter
    }
}

@MainActor
public protocol MacMachinesBackend: AnyObject {
    /// The current snapshot first, then one each time anything changes.
    func updates() -> AsyncStream<MachinesSnapshot>
    func connect(host: String, port: UInt16) async throws
    /// Josh compared the relay's code; Touch ID confirms.
    func confirmRelay(comparedCode: String) async throws
    /// Abandons an unconfirmed first setup. Fails once it has been confirmed.
    func cancelRelaySetup() throws
    /// Removes a machine's right to ask, with Touch ID.
    func remove(machineID: String) async throws
    /// Removes an iPhone's right to approve, with Touch ID.
    func removePhone(keyID: String) async throws
    func setAskPhoneAfter(_ delay: Duration)
}

@MainActor
@Observable
public final class MacMachinesModel {
    public private(set) var snapshot: MachinesSnapshot
    public var addressDraft = SetupCopy.defaultRelayAddress
    public private(set) var isWorking = false
    public private(set) var failure: String?
    /// Opens the enrolment panel for a waiting machine.
    public var review: (String) -> Void = { _ in }

    private let backend: any MacMachinesBackend

    public init(backend: any MacMachinesBackend, initial: MachinesSnapshot) {
        self.backend = backend
        self.snapshot = initial
    }

    public func followUpdates() async {
        for await next in backend.updates() { snapshot = next }
    }

    /// "mac-mini.example.ts.net:17443" into host and port.
    public var parsedAddress: (host: String, port: UInt16)? {
        let parts = addressDraft.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, !parts[0].isEmpty, let port = UInt16(parts[1]) else { return nil }
        return (String(parts[0]), port)
    }

    public func connect() async {
        guard let address = parsedAddress else { return }
        await run("Couldn't reach the relay. Check the address and that Tailscale is on.") {
            try await backend.connect(host: address.host, port: address.port)
        }
    }

    public func confirmRelay() async {
        guard case let .comparing(code, _) = snapshot.relay else { return }
        await run(SetupCopy.joiningFailed) { try await backend.confirmRelay(comparedCode: code) }
    }

    public func cancelRelaySetup() async {
        await run("The setup couldn't be cancelled.") { try backend.cancelRelaySetup() }
    }

    public func removePhone(_ keyID: String) async {
        await run("The iPhone wasn't removed. Try again.") { try await backend.removePhone(keyID: keyID) }
    }

    public func remove(_ machineID: String) async {
        await run("The machine wasn't removed. Try again.") { try await backend.remove(machineID: machineID) }
    }

    public static let phoneDelays: [Duration] = [.seconds(30), .seconds(60), .seconds(120), .seconds(300), .seconds(540)]

    public func setAskPhoneAfter(_ delay: Duration) {
        snapshot.askPhoneAfter = delay
        backend.setAskPhoneAfter(delay)
    }

    public func dismissFailure() { failure = nil }

    /// Shows the backend's own explanation when it gives one.
    private func run(_ message: String, action: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do { try await action() } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? message
        }
    }
}

public struct MacMachinesView: View {
    @Bindable var model: MacMachinesModel
    @State private var phoneToRemove: ApproverDevice?

    public init(model: MacMachinesModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section(SetupCopy.relayHeading) {
                relay
                // Pending withdrawals say more than the spinner, so they replace it.
                if model.snapshot.isApplying && model.snapshot.withdrawals.isEmpty { ApplyingLine() }
            }

            if !model.snapshot.withdrawals.isEmpty {
                Section(SetupCopy.waitingForDevices) {
                    ForEach(model.snapshot.withdrawals) { withdrawal in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(withdrawal.title).fontWeight(.medium)
                                Text(SetupCopy.withdrawalProgress(withdrawal))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        } icon: {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }

            if !model.snapshot.waiting.isEmpty {
                Section(SetupCopy.waitingToJoin) {
                    ForEach(model.snapshot.waiting) { enrolment in
                        HStack {
                            MachineLabel(name: enrolment.name,
                                detail: enrolment.tailnetNode.isEmpty
                                    ? SetupCopy.joiningDetail(enrolment) : SetupCopy.tailnetNode(enrolment.tailnetNode),
                                symbol: enrolment.kind == .machine ? "desktopcomputer" : "iphone")
                            Spacer()
                            Button(SetupCopy.review) { model.review(enrolment.id) }
                                .buttonStyle(.borderedProminent)
                                .tint(KeyringColour.signal)
                        }
                    }
                }
            }

            if !model.snapshot.approvers.isEmpty {
                Section {
                    ForEach(model.snapshot.approvers, id: \.self) { approver in
                        HStack {
                            MachineLabel(name: approver.name,
                                detail: approver.isPhone ? SetupCopy.answersWithFaceID : SetupCopy.answersWithTouchID,
                                symbol: approver.isPhone ? "iphone" : "laptopcomputer")
                            if approver.isPhone {
                                Spacer()
                                Button(SetupCopy.remove) { phoneToRemove = approver }
                                    .foregroundStyle(KeyringColour.denyText)
                                    .disabled(model.isWorking)
                            }
                        }
                    }
                    if model.snapshot.approvers.contains(where: \.isPhone) {
                        Picker(SetupCopy.askPhoneAfterOnMac, selection: phoneDelay) {
                            ForEach(MacMachinesModel.phoneDelays, id: \.self) { delay in
                                Text(SetupCopy.delay(delay)).tag(delay)
                            }
                        }
                    }
                } header: {
                    Text(SetupCopy.canApprove)
                } footer: {
                    if model.snapshot.approvers.contains(where: \.isPhone) {
                        Text(SetupCopy.macDelayFooter)
                    }
                }
            }

            Section(SetupCopy.machinesThatCanAsk) {
                if model.snapshot.machines.isEmpty {
                    Text(SetupCopy.noMachines)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.snapshot.machines) { machine in
                        HStack {
                            MachineLabel(name: machine.name,
                                detail: "\(machine.tailnetNode) · " + (machine.automaticAllowed
                                    ? SetupCopy.automaticAllowed : SetupCopy.asksEveryTime),
                                symbol: "desktopcomputer")
                            Spacer()
                            Button(SetupCopy.remove) { Task { await model.remove(machine.id) } }
                                .foregroundStyle(KeyringColour.denyText)
                                .disabled(model.isWorking)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420)
        .task { await model.followUpdates() }
        .confirmationDialog(phoneToRemove.map { SetupCopy.removePhoneTitle($0.name) } ?? "",
            isPresented: removingPhone, titleVisibility: .visible, presenting: phoneToRemove) { phone in
            Button(SetupCopy.removeWithTouchID, role: .destructive) {
                Task { await model.removePhone(phone.keyID) }
            }
        } message: { _ in
            Text(SetupCopy.removePhoneMessage)
        }
        .alert("Something went wrong", isPresented: failureShown) {
            Button("OK") { model.dismissFailure() }
        } message: {
            Text(model.failure ?? "")
        }
    }

    @ViewBuilder private var relay: some View {
        switch model.snapshot.relay {
        case .notSetUp:
            Text(SetupCopy.relayNotSetUp)
                .foregroundStyle(.secondary)
            HStack {
                TextField(SetupCopy.relayAddress, text: $model.addressDraft,
                    prompt: Text(SetupCopy.relayAddressExample))
                Button(SetupCopy.connect) { Task { await model.connect() } }
                    .disabled(model.parsedAddress == nil || model.isWorking)
            }
            Text(SetupCopy.relayAddressHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
        case let .connecting(address):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(address)…")
            }
        case let .comparing(code, address):
            VStack(alignment: .leading, spacing: 10) {
                Text(SetupCopy.compareWithSetupCode)
                    .font(.headline)
                Text("\(SetupCopy.setupCodeSource) Relay: \(address).")
                    .foregroundStyle(.secondary)
                FingerprintGrid(code)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                Text(SetupCopy.allGroupsMustMatch)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button(SetupCopy.doesNotMatch) { Task { await model.cancelRelaySetup() } }
                        .buttonStyle(DecisionButtonStyle(colour: KeyringColour.deny, height: 32))
                    Button { Task { await model.confirmRelay() } } label: {
                        Label(SetupCopy.theyMatch, systemImage: "touchid")
                    }
                    .buttonStyle(DecisionButtonStyle(colour: KeyringColour.approve, height: 32))
                }
                .disabled(model.isWorking)
            }
            .padding(.vertical, 4)
        case let .connected(address):
            StatusLine(symbol: "checkmark.circle.fill", colour: KeyringColour.approveText,
                text: SetupCopy.relayConnected(address), detail: queuedDetail)
        case let .offline(address):
            StatusLine(symbol: "antenna.radiowaves.left.and.right.slash", colour: KeyringColour.denyText,
                text: SetupCopy.relayOffline(address), detail: queuedDetail)
        }
    }

    private var queuedDetail: String? {
        model.snapshot.queuedAnswers > 0 ? SetupCopy.queuedAnswers(model.snapshot.queuedAnswers) : nil
    }

    private var phoneDelay: Binding<Duration> {
        Binding(get: { model.snapshot.askPhoneAfter }, set: { model.setAskPhoneAfter($0) })
    }

    private var removingPhone: Binding<Bool> {
        Binding(get: { phoneToRemove != nil }, set: { if !$0 { phoneToRemove = nil } })
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { model.failure != nil }, set: { if !$0 { model.dismissFailure() } })
    }
}

private struct MachineLabel: View {
    let name: String
    let detail: String
    let symbol: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}

/// Shown in the Machines and rules windows until the relay acknowledges a change.
struct ApplyingLine: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(SetupCopy.applying).foregroundStyle(.secondary)
        }
    }
}

private struct StatusLine: View {
    let symbol: String
    let colour: Color
    let text: String
    let detail: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(colour)
        }
    }
}
#endif
