// Written by AI on 2026.11.21 by model claude opus 5.5, from board 1 of the
// Paper page "Agent Keyring (Holistic)" and the copy ledger of that day.
//
// The Mac's first run, one page per state, built only from the page parts.
// Each page draws the plain value it is given; the app maps first run's saved
// state (AgentKeyringEngine/Mac/MacFirstRunFlow.swift) and the facts beside it to these
// values, and wires the buttons. Nothing here keeps state of its own.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

/// Welcome, before the steps: no step list, as the board draws it. When Agent Keyring is already set up on
/// his iPhone, Welcome offers to join that list instead, as the iPhone offers to join a Mac's.
public struct MacWelcomePage: View {
    /// Joining the list on his iPhone, as `JoiningIPhone` (AgentKeyringEngine) says.
    public enum IPhone: Equatable, Sendable {
        case found(name: String)
        case asking(name: String)
        case notAdded(name: String)
        case joined(name: String)
    }

    let mode: MacApprovalMode
    let iPhone: IPhone?
    let connect: () -> Void
    let cancel: () -> Void
    let getStarted: () -> Void

    public init(mode: MacApprovalMode = .current, iPhone: IPhone? = nil, connect: @escaping () -> Void = {},
                cancel: @escaping () -> Void = {}, getStarted: @escaping () -> Void) {
        self.mode = mode
        self.iPhone = iPhone
        self.connect = connect
        self.cancel = cancel
        self.getStarted = getStarted
    }

    private static let badges: [KeyringDeviceRowBadge] = [.brand, .brand, .brand]

    public var body: some View {
        page.frame(width: KeyringSize.macWindow.width, height: KeyringSize.macWindow.height)
    }

    @ViewBuilder private var page: some View {
        switch iPhone {
        case nil:
            KeyringPage(title: FirstRunCopy.title, sentence: FirstRunCopy.intro, sentenceColour: KeyringPalette.brand,
                        alignment: .centre, mascot: .calm,
                        primary: .advance(FirstRunCopy.getStarted, perform: getStarted)) {
                VStack(alignment: .leading, spacing: KeyringSpace.s3) {
                    ForEach(Array(FirstRunCopy.points(mode).enumerated()), id: \.element.title) { index, point in
                        KeyringDeviceRow(symbol: point.symbol, name: point.title, detail: point.body,
                                         badge: Self.badges[min(index, Self.badges.count - 1)])
                    }
                }
            }
        case let .found(name)?:
            KeyringPage(title: FirstRunCopy.continueFrom(name), sentence: FirstRunCopy.continueFromDetail(name, mode: mode),
                        alignment: .centre, mascot: .calm,
                        primary: .advance(FirstRunCopy.connectTo(name), perform: connect),
                        secondary: .plain(FirstRunCopy.setUpHere, perform: getStarted)) {
                KeyringHint(symbol: "lock.fill", title: FirstRunCopy.trustTitle, FirstRunCopy.trustDetail(name))
            }
        case let .asking(name)?:
            KeyringPage(title: FirstRunCopy.approveOn(name), sentence: FirstRunCopy.approveOnDetail(name), alignment: .centre, mascot: .waiting,
                        status: .waiting(FirstRunCopy.waitingFor(name)), secondary: .plain(FirstRunCopy.cancel, perform: cancel))
        case let .notAdded(name)?:
            KeyringPage(title: FirstRunCopy.notAddedOn(name), sentence: FirstRunCopy.notAddedDetail, alignment: .centre, mascot: .denied,
                        primary: .advance(FirstRunCopy.askAgain, perform: connect),
                        secondary: .plain(FirstRunCopy.setUpHere, perform: getStarted))
        case let .joined(name)?:
            KeyringPage(title: FirstRunCopy.connectedTo(name), sentence: FirstRunCopy.connectedDetail(name), alignment: .centre, mascot: .approved,
                        primary: .advance(FirstRunCopy.continueButton, perform: getStarted))
        }
    }
}

/// The setup window for step 1 to 4: the steps on the left, done up to this one.
public struct MacFirstRunWindow<Page: View>: View {
    let step: Int
    let mascot: KeyringMascotMood
    let page: Page

    /// `step`: 1 to 4.
    public init(step: Int, mascot: KeyringMascotMood = .calm, @ViewBuilder page: () -> Page) {
        self.step = step
        self.mascot = mascot
        self.page = page()
    }

    public var body: some View {
        KeyringSetupWindow(heading: FirstRunCopy.setupHeading, steps: FirstRunCopy.steps.enumerated().map { index, title in
            KeyringSetupStep(title, index + 1 < step ? .done : index + 1 == step ? .current : .upcoming)
        }, mascot: mascot) { page }
    }
}

// MARK: Before first run: how this Mac is used

public enum ThisMacPageState: Equatable, Sendable {
    case askHowUsed
    case forAgents
    case personalMac(failure: String?)
    case noSecureEnclave
    case keysFailed(String)
}

public struct ThisMacPageActions {
    public var chooseForAgents: () -> Void = {}
    public var choosePersonalMac: () -> Void = {}
    public var usePassword: () -> Void = {}
    public var tryAgain: () -> Void = {}
    public var back: () -> Void = {}
    public var quit: () -> Void = {}
    public init() {}
}

/// A Mac with no keys yet that has no Touch ID, or no Secure Enclave, or
/// whose keys failed: one page per state of `MacHardwareSetupFlow` (AgentKeyringEngine),
/// in the Welcome page's window, before the steps.
public struct ThisMacPage: View {

    let state: ThisMacPageState
    let actions: ThisMacPageActions

    public init(_ state: ThisMacPageState, actions: ThisMacPageActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        page.frame(width: KeyringSize.macWindow.width, height: KeyringSize.macWindow.height)
    }

    @ViewBuilder private var page: some View {
        switch state {
        case .askHowUsed:
            KeyringPage(title: ThisMacCopy.askTitle, sentence: ThisMacCopy.askBody,
                        aside: .link(ThisMacCopy.quit, perform: actions.quit)) {
                KeyringRowGroup {
                    KeyringDeviceRow(symbol: "server.rack", name: ThisMacCopy.forAgents, detail: ThisMacCopy.forAgentsDetail, badge: .brand) {
                        KeyringButton(.advance(ThisMacCopy.choose, perform: actions.chooseForAgents))
                    }
                    KeyringDeviceRow(symbol: "person.crop.circle", name: ThisMacCopy.personalMac, detail: ThisMacCopy.personalMacDetail, badge: .focus) {
                        KeyringButton(.plain(ThisMacCopy.choose, perform: actions.choosePersonalMac))
                    }
                }
            }
        case .forAgents:
            KeyringPage(title: ThisMacCopy.forAgentsTitle, sentence: ThisMacCopy.forAgentsBody,
                        primary: .advance(ThisMacCopy.quit, perform: actions.quit), secondary: .plain(ThisMacCopy.back, perform: actions.back)) {
                MacInstallCommandBlocks()
                KeyringText(ThisMacCopy.notNeeded, as: .meta)
            }
        case let .personalMac(failure):
            KeyringPage(title: ThisMacCopy.personalTitle, sentence: ThisMacCopy.personalBody, status: failure.map(KeyringStatus.problem),
                        primary: .advance(ThisMacCopy.usePassword, perform: actions.usePassword),
                        secondary: .plain(ThisMacCopy.back, perform: actions.back)) {
                KeyringHint(symbol: "touchid", ThisMacCopy.touchIDLater, tone: .plain)
            }
        case .noSecureEnclave:
            KeyringPage(title: ThisMacCopy.noChipTitle, sentence: ThisMacCopy.noChipBody,
                        primary: .advance(ThisMacCopy.quit, perform: actions.quit)) {
                MacInstallCommandBlocks()
            }
        case let .keysFailed(reason):
            KeyringPage(title: ThisMacCopy.keysFailedTitle, status: .problem(reason),
                        primary: .advance(ThisMacCopy.tryAgain, perform: actions.tryAgain),
                        aside: .link(ThisMacCopy.quit, perform: actions.quit))
        }
    }
}

/// The setup steps for a Mac for agents, with the command tucked behind Copy Prompt / Copy Command.
struct MacInstallCommandBlocks: View {
    var body: some View {
        KeyringSteps(ThisMacCopy.agentSetupSteps)
        HStack(spacing: KeyringSpace.s2) {
            KeyringButton(.advance(DeviceSheetCopy.copyPrompt) { Self.copy(ThisMacCopy.installPrompt) })
            KeyringButton(.plain(DeviceSheetCopy.copyCommand) { Self.copy(ThisMacCopy.installCommand) })
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: Step 1: Try a password request

public enum MacPracticePageState: Equatable, Sendable {
    case notSent
    /// The practice card is beside the window.
    case waiting
    case approved
    case denied(reply: String)
}

public struct MacPracticePageActions {
    public var send: () -> Void = {}
    public var openTouchIDSettings: () -> Void = {}
    public var back: () -> Void = {}
    public var continueOn: () -> Void = {}
    public init() {}
}

public struct MacPracticePage: View {

    let state: MacPracticePageState
    /// Touch ID as it is now: with the lid closed, no fingerprint or no Touch ID keyboard, the practice request cannot be answered here.
    let approver: MacApproverState
    /// How this Mac approves, for "Approve: click the green button, then …".
    let mode: MacApprovalMode
    let actions: MacPracticePageActions

    public init(_ state: MacPracticePageState, approver: MacApproverState, mode: MacApprovalMode = .current, actions: MacPracticePageActions) {
        self.state = state
        self.approver = approver
        self.mode = mode
        self.actions = actions
    }

    private var answered: Bool {
        switch state {
        case .approved, .denied: true
        case .notSent, .waiting: false
        }
    }

    public var body: some View {
        MacFirstRunWindow(step: 1, mascot: mascot) {
            KeyringPage(step: (1, 5), title: FirstRunCopy.practiceTitle, sentence: FirstRunCopy.practiceBody,
                        primary: .advance(FirstRunCopy.continueButton, isEnabled: answered, perform: actions.continueOn),
                        secondary: .plain(FirstRunCopy.back, perform: actions.back)) {
                switch state {
                case .notSent, .waiting:
                    KeyringHint(symbol: "hand.tap", FirstRunCopy.practiceTrigger, tone: .plain)
                case .approved:
                    KeyringConfirmation(FirstRunCopy.youApproved, detail: FirstRunCopy.youApprovedDetail)
                case let .denied(reply) where reply.isEmpty:
                    KeyringConfirmation(FirstRunCopy.youDenied, detail: FirstRunCopy.youDeniedDetail, tone: .denied)
                case let .denied(reply):
                    KeyringConfirmation(FirstRunCopy.youDeniedAndReplied, detail: FirstRunCopy.youDeniedAndRepliedDetail(reply), tone: .denied)
                }
                KeyringButton(answered ? .plain(FirstRunCopy.sendAnother, isEnabled: approver == .ready, perform: actions.send)
                    : .advance(FirstRunCopy.sendPractice, isEnabled: state == .notSent && approver == .ready, perform: actions.send))
                switch approver {
                case .ready:
                    VStack(alignment: .leading, spacing: KeyringSpace.s2) {
                        KeyringText(FirstRunCopy.howToApprove(mode))
                        KeyringText(FirstRunCopy.howToDeny)
                    }
                case .lidClosed:
                    KeyringStatusLine(.problem(FirstRunCopy.lidClosed))
                case .needsFingerprint:
                    KeyringStatusLine(.problem(FirstRunCopy.needsFingerprint),
                                      action: .link(FirstRunCopy.openTouchIDSettings, perform: actions.openTouchIDSettings))
                case .touchIDMissing:
                    KeyringStatusLine(.problem(FirstRunCopy.touchIDMissing))
                }
            }
        }
    }

    private var mascot: KeyringMascotMood {
        switch state {
        case .notSent: .calm
        case .waiting: .curious
        case .approved: .approved
        case .denied: .denied
        }
    }
}

// MARK: AutoFill export sheet

/// "Agent Keyring isn't in the list?": a sheet over the copy page.
public struct MacAllowExportSheet: View {
    let openSettings: () -> Void
    let cancel: () -> Void

    public init(openSettings: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.openSettings = openSettings
        self.cancel = cancel
    }

    public static let width: CGFloat = 460

    public var body: some View {
        KeyringPage(title: FirstRunCopy.allowExportTitle, sentence: FirstRunCopy.allowExportBody,
                    primary: .advance(FirstRunCopy.openAutoFillSettings, perform: openSettings),
                    secondary: .plain(FirstRunCopy.cancel, perform: cancel))
            .frame(width: Self.width)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Step 3: Connect an agent

public enum MacConnectAgentOutcome: Equatable, Sendable {
    case notTried
    case worked(agent: String)
    case denied(agent: String)
}

public struct MacConnectAgentPageActions {
    public var skipTest: () -> Void = {}
    public var back: () -> Void = {}
    public var continueOn: () -> Void = {}
    public init() {}
}

public struct MacConnectAgentPage: View {

    let outcome: MacConnectAgentOutcome
    let agentNote: String
    let actions: MacConnectAgentPageActions

    public init(_ outcome: MacConnectAgentOutcome, agentNote: String = FirstRunCopy.agentNote, actions: MacConnectAgentPageActions) {
        self.outcome = outcome
        self.agentNote = agentNote
        self.actions = actions
    }

    public var body: some View {
        MacFirstRunWindow(step: 4, mascot: outcome == .notTried ? .calm : .approved) {
            KeyringPage(step: (4, 5), title: FirstRunCopy.connectTitle, sentence: FirstRunCopy.connectBody, status: status,
                        primary: .advance(FirstRunCopy.continueButton, isEnabled: outcome != .notTried, perform: actions.continueOn),
                        secondary: .plain(FirstRunCopy.back, perform: actions.back),
                        aside: outcome == .notTried ? .link(FirstRunCopy.skipTest, perform: actions.skipTest) : nil) {
                MacAgentNoteBlocks(agentNote: agentNote)
                if outcome == .notTried { KeyringText(FirstRunCopy.whatToExpect, as: .meta) }
            }
        }
    }

    private var status: KeyringStatus? {
        switch outcome {
        case .notTried: nil
        case let .worked(agent): .done(FirstRunCopy.agentWorked(agent))
        case let .denied(agent): .done(FirstRunCopy.agentDenied(agent))
        }
    }
}

/// The note for an agent's instructions and the request to try: on Connect an agent and in Devices' sheet.
public struct MacAgentNoteBlocks: View {
    let agentNote: String
    public init(agentNote: String = FirstRunCopy.agentNote) { self.agentNote = agentNote }

    public var body: some View {
        KeyringCopyBlock(FirstRunCopy.instructionLabel, text: agentNote)
        KeyringCopyBlock(FirstRunCopy.tryItLabel, text: FirstRunCopy.tryItText)
    }
}

/// Devices' "Tell Your Agents…": the same note, in a sheet.
public struct MacAgentNoteSheet: View {
    let agentNote: String
    let done: () -> Void

    public init(agentNote: String = FirstRunCopy.agentNote, done: @escaping () -> Void) {
        self.agentNote = agentNote
        self.done = done
    }

    public var body: some View {
        KeyringPage(title: FirstRunCopy.connectTitle, sentence: FirstRunCopy.connectBody,
                    primary: .advance(DeviceSheetCopy.done, perform: done)) {
            MacAgentNoteBlocks(agentNote: agentNote)
        }
        .frame(width: MacDeviceSheet.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Step 4: Ready

/// What Ready says was copied.
public enum SetupCopiedSummary: Equatable, Sendable {
    case passwords(Int)
    case testPasswordOnly
}

/// Each row as the members list says now.
public struct SetupDevicesSummary: Equatable, Sendable {
    public var iPhone: String?
    public var watch: String?
    public var computers: [String]
    public init(iPhone: String? = nil, watch: String? = nil, computers: [String] = []) {
        self.iPhone = iPhone
        self.watch = watch
        self.computers = computers
    }
}

public struct MacReadyPageActions {
    public var addIPhone: () -> Void = {}
    public var addComputer: () -> Void = {}
    public var showPasswords: () -> Void = {}
    public init() {}
}

public struct MacReadyPage: View {

    let copied: SetupCopiedSummary
    let devices: SetupDevicesSummary
    let actions: MacReadyPageActions

    public init(copied: SetupCopiedSummary, devices: SetupDevicesSummary, actions: MacReadyPageActions) {
        self.copied = copied
        self.devices = devices
        self.actions = actions
    }

    public var body: some View {
        MacFirstRunWindow(step: 5, mascot: .approved) {
            KeyringPage(step: (5, 5), primary: .advance(FirstRunCopy.showPasswords, perform: actions.showPasswords)) {
                KeyringConfirmation(FirstRunCopy.ready, detail: {
                    switch copied {
                    case let .passwords(count): FirstRunCopy.readyCopied(count)
                    case .testPasswordOnly: FirstRunCopy.readyTestOnly
                    }
                }())
                KeyringText(FirstRunCopy.otherDevices, as: .heading)
                KeyringRowGroup {
                    if let phone = devices.iPhone {
                        KeyringDeviceRow(symbol: "iphone", name: FirstRunCopy.iPhone, detail: FirstRunCopy.added(phone, under: FirstRunCopy.iPhone), tone: .approved)
                    } else {
                        KeyringDeviceRow(symbol: "iphone", name: FirstRunCopy.iPhone, detail: FirstRunCopy.iPhoneDetail) {
                            KeyringButton(.plain(FirstRunCopy.addButton, perform: actions.addIPhone))
                        }
                    }
                    if let watch = devices.watch {
                        KeyringDeviceRow(symbol: "applewatch", name: FirstRunCopy.watch, detail: FirstRunCopy.added(watch, under: FirstRunCopy.watch), tone: .approved)
                    } else {
                        KeyringDeviceRow(symbol: "applewatch", name: FirstRunCopy.watch, detail: FirstRunCopy.watchDetail)
                    }
                    KeyringDeviceRow(symbol: "server.rack", name: FirstRunCopy.computers,
                                     detail: devices.computers.isEmpty ? FirstRunCopy.computersDetail : FirstRunCopy.added(devices.computers),
                                     tone: devices.computers.isEmpty ? .plain : .approved) {
                        KeyringButton(.plain(FirstRunCopy.addButton, perform: actions.addComputer))
                    }
                }
            }
        }
    }
}
#endif
