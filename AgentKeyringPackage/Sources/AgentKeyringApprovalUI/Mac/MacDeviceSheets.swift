// Written by AI on 2026.11.21 by model claude opus 5.5, from board 2 of the
// Paper page "Agent Keyring (Holistic)" and the copy ledger of that day.
//
// The sheets that add an iPhone or another computer, opened from Ready and
// from Devices. Each draws one state of the Mac's door and joins
// (docs/state-machines.md, "Adding an iPhone or a computer"), which the app
// works out from MacDevice; nothing here keeps state of its own.

#if os(macOS)
import AgentKeyringDesign
import AppKit
import SwiftUI

public enum MacDeviceSheet {
    /// Every device sheet's width, the width the checks host it at.
    public static let width: CGFloat = 480
}

public struct MacAddIPhoneSheet: View {
    public enum State: Equatable, Sendable {
        /// This Mac has no Tailscale address.
        case noTailscale
        /// The door could not open, with the sentence that says why.
        case doorProblem(String)
        /// Waiting for his iPhone. `notAdded`: an iPhone he denied, or whose request ran out or was cancelled.
        case waiting(notAdded: String?)
        /// An iPhone asked to join: the card is beside the window.
        case joinAsked(name: String)
        case copying(name: String, done: Int, total: Int)
        case stopped(name: String, done: Int, total: Int, reason: String)
        case added(name: String)
    }

    let state: State
    let checkAgain: () -> Void
    let close: () -> Void

    public init(_ state: State, checkAgain: @escaping () -> Void, close: @escaping () -> Void) {
        self.state = state
        self.checkAgain = checkAgain
        self.close = close
    }

    public var body: some View {
        KeyringPage(title: DeviceSheetCopy.addIPhoneTitle, sentence: DeviceSheetCopy.addIPhoneBody, status: status,
                    primary: primary, secondary: secondary) {
            switch state {
            case .noTailscale, .doorProblem:
                EmptyView()
            case .waiting:
                KeyringQRBlock(url: DeviceSheetCopy.testFlightLink, steps: DeviceSheetCopy.addIPhoneSteps)
            case let .joinAsked(name):
                KeyringQRBlock(url: DeviceSheetCopy.testFlightLink, steps: DeviceSheetCopy.addIPhoneSteps)
                KeyringHint(symbol: "touchid", DeviceSheetCopy.approveBeside(name))
            case let .copying(name, _, _), let .stopped(name, _, _, _):
                KeyringConfirmation(SetupCopy.added(name), detail: SetupCopy.addedPhoneDetail)
            case let .added(name):
                KeyringConfirmation(SetupCopy.added(name), detail: SetupCopy.addedPhoneDetail)
            }
        }
        .frame(width: MacDeviceSheet.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var status: KeyringStatus? {
        switch state {
        case .noTailscale: .problem(DeviceSheetCopy.phoneNoTailscale)
        case let .doorProblem(reason): .problem(reason)
        case let .waiting(notAdded): notAdded.map { .problem(SetupCopy.notAdded($0)) }
        case .joinAsked: nil
        case let .copying(name, done, total): .waiting(DeviceSheetCopy.copyingTo(name, done: done, total: total))
        case let .stopped(_, done, total, reason): .problem(SetupCopy.stoppedCopying(done: done, total: total, reason: reason))
        case .added: nil
        }
    }

    private var primary: KeyringAction {
        switch state {
        case .noTailscale, .doorProblem: .plain(DeviceSheetCopy.checkAgain, perform: checkAgain)
        case .added, .copying, .stopped: .advance(DeviceSheetCopy.done, perform: close)
        case .waiting, .joinAsked: .plain(DeviceSheetCopy.doThisLater, perform: close)
        }
    }

    private var secondary: KeyringAction? {
        switch state {
        case .noTailscale, .doorProblem: .plain(DeviceSheetCopy.doThisLater, perform: close)
        default: nil
        }
    }
}

public struct MacAddComputerSheet: View {
    public enum State: Equatable, Sendable {
        case noTailscale
        case doorProblem(String)
        /// The command with its one-time invite, and when the invite runs out (as a time of day).
        case invite(command: String, until: String)
        /// A computer used the invite: the card is beside the window.
        case joinAsked(name: String)
        case added(name: String)
        /// He denied the computer; the invite is used up.
        case notAdded(name: String)
        /// Ten minutes passed.
        case expired
        /// Two computers used the same invite, so it was withdrawn and neither was shown.
        case withdrawn
    }

    let state: State
    let actions: Actions

    public struct Actions {
        public var checkAgain: () -> Void = {}
        public var newInvite: () -> Void = {}
        public var close: () -> Void = {}
        public init() {}
    }

    public init(_ state: State, actions: Actions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        KeyringPage(title: DeviceSheetCopy.addComputerTitle, sentence: DeviceSheetCopy.addComputerBody, status: status,
                    primary: primary, secondary: secondary) {
            switch state {
            case let .invite(command, until):
                // The command itself is not shown: its invite is one unbroken
                // word of about 250 characters, which no part can wrap without
                // splitting it (see the report of 21 November).
                HStack(spacing: KeyringSpace.s2) {
                    KeyringButton(.advance(DeviceSheetCopy.copyPrompt) { Self.copy(DeviceSheetCopy.enrolPrompt(command)) })
                    KeyringButton(.plain(DeviceSheetCopy.copyCommand) { Self.copy(command) })
                }
                KeyringText(DeviceSheetCopy.worksUntil(until), as: .meta)
            case let .joinAsked(name):
                KeyringHint(symbol: "touchid", DeviceSheetCopy.approveBeside(name))
            case let .added(name):
                KeyringConfirmation(SetupCopy.added(name), detail: SetupCopy.addedComputerDetail(name))
            case .noTailscale, .doorProblem, .notAdded, .expired, .withdrawn:
                EmptyView()
            }
        }
        .frame(width: MacDeviceSheet.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var status: KeyringStatus? {
        switch state {
        case .noTailscale: .problem(DeviceSheetCopy.computerNoTailscale)
        case let .doorProblem(reason): .problem(reason)
        case .invite, .added, .joinAsked: nil
        case let .notAdded(name): .problem(SetupCopy.notAdded(name))
        case .expired: .problem(DeviceSheetCopy.expired)
        case .withdrawn: .problem(DeviceSheetCopy.withdrawn)
        }
    }

    private var primary: KeyringAction {
        switch state {
        case .noTailscale, .doorProblem: .plain(DeviceSheetCopy.checkAgain, perform: actions.checkAgain)
        case .notAdded, .expired, .withdrawn: .advance(DeviceSheetCopy.createNewInvite, perform: actions.newInvite)
        case .added: .advance(DeviceSheetCopy.done, perform: actions.close)
        case .invite, .joinAsked: .plain(DeviceSheetCopy.done, perform: actions.close)
        }
    }

    private var secondary: KeyringAction? {
        switch state {
        case .noTailscale, .doorProblem, .notAdded, .expired, .withdrawn: .plain(FirstRunCopy.cancel, perform: actions.close)
        case .invite, .joinAsked, .added: nil
        }
    }
}
#endif
