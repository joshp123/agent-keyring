// Written by AI on 2026.11.20 by model claude opus 5.5, from the Paper board
// "Mac" (page "First run and the app").
//
// The windows first run shares with Devices: "Tell your agents", a computer
// that stays on, adding an iPhone, an Apple Watch or a computer, and a
// practice request on each device. Each is drawn from the facts as they are
// now (the members list, the leases, the last practice results); the sheet
// Devices opens keeps only which of its windows is showing.

#if os(macOS)
import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringProtocol
import AppKit
import Foundation
import Observation
import SwiftUI

@available(macOS 26.0, *)
@MainActor
public enum SetupScreens {
    public static func header(_ copied: FirstRun.Copied) -> CopiedHeader {
        switch copied {
        case let .passwords(count): CopiedHeader(title: FirstRunCopy.copied(count), detail: FirstRunCopy.mustAskAny, sample: false)
        case .sample: CopiedHeader(title: FirstRunCopy.sampleAdded, detail: FirstRunCopy.sampleDetail, sample: true)
        }
    }

    public static func tellAgents(_ model: MirrorAppModel, copied: FirstRun.Copied?) -> FirstRunScreen {
        .tellAgents(header: copied.map(header), approved: model.firstApprovedRequest.map {
            FirstRunCopy.approvedRequest(agent: $0.agent, site: $0.site)
        })
    }

    static func joined(_ model: MirrorAppModel, _ kind: Agentkeyring_V2_DeviceKind) -> String? {
        model.device?.members?.devices.first { $0.kind == kind }?.label
    }

    public static func addPhone(_ model: MirrorAppModel) -> FirstRunScreen { .addPhone(added: joined(model, .iphone)) }
    public static func addWatch(_ model: MirrorAppModel) -> FirstRunScreen { .addWatch(added: joined(model, .watch)) }

    /// The computers that have joined, other than this Mac and the one that stays on.
    public static func addComputers(_ model: MirrorAppModel, command: String?) -> FirstRunScreen {
        let device = model.device
        let others = (device?.members?.machines ?? [])
            .filter { $0.machineID != device?.ownMachineID && $0.machineID != device?.alwaysOnMachineID }.map(\.label)
        return .addComputers(command: command, joined: others)
    }

    /// The one-time command for "Add other computers"; nil if this Mac reaches no computer that stays on.
    public static func enrolCommand(_ model: MirrorAppModel) -> String? {
        (try? model.device?.inviteMachine()).map(FirstRunCopy.enrolCommand)
    }

    /// Every device he answers on, with its last practice result.
    public static func practiceRows(_ model: MirrorAppModel) -> [PracticeRow] {
        let own = model.thisMacDeviceKey
        let devices = model.device?.members?.devices.map { ($0.keyID, $0.label, $0.kind) }
            ?? [(own, Host.current().localizedName ?? "Mac", Agentkeyring_V2_DeviceKind.mac)]
        return devices.map { key, name, kind in
            let isThisMac = key == own
            let symbol = kind == .iphone ? "iphone" : kind == .watch ? "applewatch" : "laptopcomputer"
            let answers = kind == .iphone ? MainWindowCopy.phoneAnswers : kind == .watch ? MainWindowCopy.watchAnswers : MainWindowCopy.macAnswers
            let plain = isThisMac ? MainWindowCopy.thisMac + " · " + answers : answers
            let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
            let (detail, tone, canSend): (String, PracticeRow.Tone, Bool) = switch model.practiceResults[key] {
            case nil: (plain, .plain, true)
            case .sent?: (isThisMac ? FirstRunCopy.practiceSentHere : FirstRunCopy.practiceSending, .plain, false)
            case let .withApple(at)?: (FirstRunCopy.practiceWithApple(time(at)), .plain, false)
            case let .arrived(at, _)?:
                (kind == .watch ? FirstRunCopy.practiceOnWrist(time(at)) : FirstRunCopy.practiceOnPhone(time(at)), .plain, false)
            case let .approved(at)?: (FirstRunCopy.practiceApprovedAt(time(at), touchID: isThisMac), .approved, true)
            case let .denied(at, reply)?: (FirstRunCopy.practiceDeniedAt(time(at), reply: reply), .denied, true)
            case .unanswered?: (FirstRunCopy.practiceUnanswered, .plain, true)
            case let .failed(message)?: (message, .denied, true)
            }
            return PracticeRow(id: key, name: name, symbol: symbol, detail: detail, tone: tone, canSend: canSend)
        }
    }

    /// Ready: with an iPhone or Apple Watch added, or this Mac alone.
    public static func ready(_ model: MirrorAppModel) -> FirstRunScreen {
        let devices = model.device?.members?.devices ?? []
        return .ready(alone: !devices.contains { $0.kind == .iphone || $0.kind == .watch }, sampleOnly: model.status?.sampleOnly == true)
    }
}

/// Connect on "Approve from your iPhone and Apple Watch": the address, then
/// macOS's Touch ID dialog, then joined; or the reason it failed.
@available(macOS 26.0, *)
@MainActor
@Observable
public final class ConnectFlow {
    public enum State: Equatable { case idle, waiting(name: String), failed(String) }
    public private(set) var state = State.idle
    private let backend: AppMainWindowBackend

    public init(model: MirrorAppModel) { backend = AppMainWindowBackend(model: model) }

    /// The computer that stays on which announced itself, by name; nil if none did.
    public var offered: String? { backend.offeredRelay }

    public func connectOffered(then joined: @escaping @MainActor () -> Void) {
        guard let name = offered else { return }
        run(name, then: joined) { try await self.backend.connectOffered() }
    }

    public func connect(_ address: String, then joined: @escaping @MainActor () -> Void) {
        let name = address.split(separator: ":").first.map(String.init) ?? address
        run(name, then: joined) { try await self.backend.connectRelay(address) }
    }

    private func run(_ name: String, then joined: @escaping @MainActor () -> Void, connecting: @escaping @MainActor () async throws -> Void) {
        if case .waiting = state { return }
        state = .waiting(name: name)
        Task {
            do {
                try await connecting()
                state = .idle
                joined()
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed((error as? LocalizedError)?.errorDescription ?? MessageCopy.somethingWentWrong)
            }
        }
    }

    /// The window for a computer that stays on, as Connect has left it.
    public var screen: FirstRunScreen {
        switch state {
        case .idle: .stayingOn(failure: nil, offered: offered)
        case let .waiting(name): .connecting(name: name)
        case let .failed(message): .stayingOn(failure: message, offered: offered)
        }
    }
}

/// The sheet: which of its windows shows is its only state.
@available(macOS 26.0, *)
public struct SetupSheet: View {
    enum Step { case stayingOn, phone, watch, computers, tellAgents }
    let model: MirrorAppModel
    let close: () -> Void
    @State private var step: Step
    @State private var connect: ConnectFlow
    @State private var command: String?

    public init(_ sheet: DevicesSheet, model: MirrorAppModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        let joined = model.device?.isJoined == true
        let hasPhone = model.device?.members?.devices.contains { $0.kind == .iphone } == true
        let first: Step = switch sheet {
        case .tellAgents: .tellAgents
        case .addPhoneOrWatch: joined ? (hasPhone ? .watch : .phone) : .stayingOn
        case .addComputer: joined ? .computers : .stayingOn
        }
        _step = State(initialValue: first)
        _connect = State(initialValue: ConnectFlow(model: model))
        self.sheet = sheet
    }

    private let sheet: DevicesSheet

    public var body: some View {
        MacFirstRunView(screen: screen, actions: actions)
            .onAppear { if step == .computers, command == nil { command = SetupScreens.enrolCommand(model) } }
    }

    private var screen: FirstRunScreen {
        switch step {
        case .stayingOn: connect.screen
        case .phone: SetupScreens.addPhone(model)
        case .watch: SetupScreens.addWatch(model)
        case .computers: SetupScreens.addComputers(model, command: command)
        case .tellAgents: SetupScreens.tellAgents(model, copied: nil)
        }
    }

    private var actions: FirstRunActions {
        var actions = FirstRunActions()
        actions.useThisMacAlone = close
        let connected: @MainActor () -> Void = {
            if sheet == .addComputer { command = SetupScreens.enrolCommand(model); step = .computers } else { step = .phone }
        }
        actions.connect = { address in connect.connect(address, then: connected) }
        actions.connectOffered = { connect.connectOffered(then: connected) }
        actions.skip = close
        actions.continueOn = {
            if step == .phone { step = .watch } else { close() }
        }
        return actions
    }
}
#endif
