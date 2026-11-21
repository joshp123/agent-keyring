// Written by AI on 2026.11.20 by model claude opus 5.5; rebuilt on 2026.11.21
// by the same model for the four local steps and the device sheets.
//
// Maps first run's saved state, a copy from Passwords and the Mac's door and
// joins to the plain values the pages draw (AgentKeyringApprovalUI,
// MacSetupPages.swift and MacDeviceSheets.swift), and wires their buttons.
// Every value is read from where it lives, each time a page is drawn.

#if os(macOS)
import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringProtocol
import AppKit
import Foundation
import SwiftUI

@available(macOS 26.0, *)
@MainActor
public enum SetupScreens {
    /// Practice as step 1 draws it.
    public static func practice(_ practice: FirstRun.Practice) -> MacPracticePage.State {
        switch practice {
        case .notSent: .notSent
        case .waiting: .waiting
        case .approved: .approved
        case let .denied(reply): .denied(reply: reply)
        }
    }

    /// His own passwords are in the list, not only the test password.
    public static func copiedCount(_ model: MirrorAppModel) -> Int? {
        guard let status = model.status, status.sampleOnly != true else { return nil }
        // The list always holds the one test password beside his own.
        return max(status.credentialItemCount - 1, 0)
    }

    /// "Copy your passwords" as the page draws it, from the copy in progress and the list.
    public static func copy(_ model: MirrorAppModel, inFirstRun: Bool) -> MacCopyPage.State {
        switch model.passwordsCopy {
        case .copying: return .copying
        case .noneArrived: return .noneArrived
        case .waiting: return model.problem.map(MacCopyPage.State.failed) ?? .waiting
        case .steps, .allowExport, nil:
            if let problem = model.problem { return .failed(problem) }
            if inFirstRun, let count = copiedCount(model) { return .copied(count: count) }
            return .guide
        }
    }

    public static func connectAgent(_ outcome: FirstRun.ConnectAgent) -> MacConnectAgentPage.Outcome {
        switch outcome {
        case .notTried: .notTried
        case let .worked(agent): .worked(agent: agent)
        case let .denied(agent): .denied(agent: agent)
        }
    }

    public static func readyCopied(_ model: MirrorAppModel) -> MacReadyPage.Copied {
        copiedCount(model).map(MacReadyPage.Copied.passwords) ?? .testPasswordOnly
    }

    /// Each row on Ready, from the members list as it is now.
    public static func readyDevices(_ model: MirrorAppModel) -> MacReadyPage.Devices {
        let device = model.device
        let devices = device?.members?.devices ?? []
        let filling = device?.filling?.deviceKeyID
        return MacReadyPage.Devices(
            iPhone: devices.first { $0.kind == .iphone && $0.keyID != filling }?.label,
            watch: devices.first { $0.kind == .watch }?.label,
            computers: (device?.members?.machines ?? []).filter { $0.machineID != device?.ownMachineID }.map(\.label))
    }

    // MARK: The device sheets

    /// The door's state, when it stops a device being added.
    static func doorProblem(_ device: MacDevice?) -> String?? {
        switch device?.door {
        case nil: .some(MessageCopy.noKeysYet)
        case .noTailscale?: .some(nil)
        case let .failed(reason)?: .some(MessageCopy.doorClosed(reason))
        case .opening?, .open?: .none
        }
    }

    /// "Add your iPhone". `opened`: when the sheet opened, so only an iPhone added or refused since then counts.
    public static func addIPhone(_ model: MirrorAppModel, opened: Date, known: Set<String>) -> MacAddIPhoneSheet.State {
        let device = model.device
        if case let .some(problem) = doorProblem(device) { return problem.map(MacAddIPhoneSheet.State.doorProblem) ?? .noTailscale }
        guard let device else { return .noTailscale }
        let listed = Dictionary((device.members?.devices ?? []).map { ($0.keyID, $0.kind) }, uniquingKeysWith: { first, _ in first })
        if let filling = device.filling, listed[filling.deviceKeyID] == .iphone, !known.contains(filling.deviceKeyID) {
            if let failure = filling.failure {
                return .stopped(name: filling.label, done: filling.done, total: filling.total, reason: failure)
            }
            return .copying(name: filling.label, done: filling.done, total: filling.total)
        }
        if let added = device.members?.devices.first(where: { $0.kind == .iphone && !known.contains($0.keyID) }) {
            return .added(name: added.label)
        }
        let phones = device.joinHistory.filter { $0.joiner == .device(.iphone) }
        if let asking = phones.first(where: { $0.state == .waiting }) { return .joinAsked(name: asking.label) }
        let refused = phones.first.flatMap { $0.asked >= opened && [.refused, .expired, .withdrawn].contains($0.state) ? $0.label : nil }
        return .waiting(notAdded: refused)
    }

    /// The iPhones already added when the sheet opens: adding another is still possible.
    public static func knownIPhones(_ model: MirrorAppModel) -> Set<String> {
        Set((model.device?.members?.devices ?? []).filter { $0.kind == .iphone }.map(\.keyID))
    }

    /// "Add another computer", for the invite the sheet holds.
    public static func addComputer(_ model: MirrorAppModel, invite: MacDevice.MachineInvite?, now: Date) -> MacAddComputerSheet.State {
        let device = model.device
        if case let .some(problem) = doorProblem(device) { return problem.map(MacAddComputerSheet.State.doorProblem) ?? .noTailscale }
        guard let device else { return .noTailscale }
        guard let invite else { return .starting }
        let joins = device.joinHistory.filter { $0.joiner == .computer && $0.secret == invite.secret }
        if joins.contains(where: { $0.state == .withdrawn }) { return .withdrawn }
        if let join = joins.first {
            switch join.state {
            case .waiting: return .joinAsked(name: join.label)
            case .approved: return .added(name: join.label)
            case .refused: return .notAdded(name: join.label)
            default: return .expired
            }
        }
        if invite.expires <= now { return .expired }
        return .invite(command: DeviceSheetCopy.enrolCommand(invite.link), until: AccessRequestCopy.clock(invite.expires))
    }
}

/// "Add your iPhone" in a sheet, from Ready or Devices. It holds only when it opened and which iPhones were there.
@available(macOS 26.0, *)
public struct AddIPhoneSheet: View {
    let model: MirrorAppModel
    let close: () -> Void
    @State private var opened = Date()
    @State private var known: Set<String>

    public init(model: MirrorAppModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        _known = State(initialValue: SetupScreens.knownIPhones(model))
    }

    public var body: some View {
        MacAddIPhoneSheet(SetupScreens.addIPhone(model, opened: opened, known: known),
                          checkAgain: { model.device?.checkAddress() }, close: close)
    }
}

/// "Add another computer" in a sheet. It holds the invite it made, and a new one on Create New Invite.
@available(macOS 26.0, *)
public struct AddComputerSheet: View {
    let model: MirrorAppModel
    let close: () -> Void
    @State private var invite: MacDevice.MachineInvite?

    public init(model: MirrorAppModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
    }

    public var body: some View {
        // Drawn again when the invite runs out, so Expired shows on time.
        TimelineView(.explicit(invite.map { [$0.expires] } ?? [])) { context in
            MacAddComputerSheet(SetupScreens.addComputer(model, invite: invite, now: context.date), actions: actions)
        }
        .onAppear { if invite == nil { makeInvite() } }
        .onChange(of: model.device?.door) { if invite == nil { makeInvite() } }
    }

    private var actions: MacAddComputerSheet.Actions {
        var actions = MacAddComputerSheet.Actions()
        actions.checkAgain = {
            model.device?.checkAddress()
            if invite == nil { makeInvite() }
        }
        actions.newInvite = makeInvite
        actions.close = close
        return actions
    }

    private func makeInvite() {
        invite = try? model.device?.machineInvite()
    }
}
#endif
