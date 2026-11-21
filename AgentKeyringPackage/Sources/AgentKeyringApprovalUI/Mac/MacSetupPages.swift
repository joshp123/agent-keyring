// Written by AI on 2026.11.21 by model claude opus 5.5, from board 1 of the
// Paper page "Agent Keyring (Holistic)" and the copy ledger of that day.
//
// The Mac's first run, one page per state, built only from the page parts.
// Each page draws the plain value it is given; the app maps first run's saved
// state (AgentKeyringFeature/FirstRun.swift) and the facts beside it to these
// values, and wires the buttons. Nothing here keeps state of its own.

#if os(macOS)
import AgentKeyringDesign
import SwiftUI

/// Welcome, before the steps: no step list, as the board draws it.
public struct MacWelcomePage: View {
    let getStarted: () -> Void

    public init(getStarted: @escaping () -> Void) { self.getStarted = getStarted }

    public var body: some View {
        KeyringPage(title: FirstRunCopy.title, sentence: FirstRunCopy.intro, alignment: .centre, mascot: .calm,
                    primary: .advance(FirstRunCopy.getStarted, perform: getStarted)) {
            VStack(alignment: .leading, spacing: KeyringSpace.s2) {
                ForEach(FirstRunCopy.points, id: \.title) { point in
                    KeyringDeviceRow(symbol: point.symbol, name: point.title, detail: point.body)
                }
            }
        }
        .frame(width: KeyringSize.macWindow.width, height: KeyringSize.macWindow.height)
    }
}

/// The setup window for step 1 to 4: the steps on the left, done up to this one.
public struct MacFirstRunWindow<Page: View>: View {
    let step: Int
    let mascot: KeyringMascot.Mood
    let page: Page

    /// `step`: 1 to 4.
    public init(step: Int, mascot: KeyringMascot.Mood = .calm, @ViewBuilder page: () -> Page) {
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

// MARK: Step 1: Try a password request

public struct MacPracticePage: View {
    public enum State: Equatable, Sendable {
        case notSent
        /// The practice card is beside the window.
        case waiting
        case approved
        case denied(reply: String)
    }

    let state: State
    /// Touch ID as it is now: with the lid closed or no fingerprint, the practice request cannot be answered here.
    let approver: MacApprover.State
    let actions: Actions

    public struct Actions {
        public var send: () -> Void = {}
        public var openTouchIDSettings: () -> Void = {}
        public var back: () -> Void = {}
        public var continueOn: () -> Void = {}
        public init() {}
    }

    public init(_ state: State, approver: MacApprover.State, actions: Actions) {
        self.state = state
        self.approver = approver
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
            KeyringPage(step: (1, 4), title: FirstRunCopy.practiceTitle, sentence: FirstRunCopy.practiceBody,
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
                        KeyringText(FirstRunCopy.howToApprove)
                        KeyringText(FirstRunCopy.howToDeny)
                    }
                case .lidClosed:
                    KeyringStatusLine(.problem(FirstRunCopy.lidClosed))
                case .needsFingerprint:
                    KeyringStatusLine(.problem(FirstRunCopy.needsFingerprint),
                                      action: .link(FirstRunCopy.openTouchIDSettings, perform: actions.openTouchIDSettings))
                }
            }
        }
    }

    private var mascot: KeyringMascot.Mood {
        switch state {
        case .notSent: .calm
        case .waiting: .curious
        case .approved: .approved
        case .denied: .denied
        }
    }
}

// MARK: Step 2: Copy your passwords

/// "Copy your passwords": first run's step 2, and the main window's Copy Again.
public struct MacCopyPage: View {
    public enum State: Equatable, Sendable {
        case guide
        /// After Open Passwords: the guide stays, and nothing hurries him.
        case waiting
        /// Five minutes after Open Passwords, nothing has arrived.
        case noneArrived
        case copying
        /// His passwords are copied (first run only: the main window goes back to its list).
        case copied(count: Int)
        /// The last copy failed, with the reason.
        case failed(String)
    }

    let state: State
    /// Which of the guide's five steps shows: 1 to 5.
    let guideStep: Int
    /// The earlier Agent Keyring is on this Mac, so Passwords lists two names alike.
    let earlierVersion: Bool
    /// In first run: step 2 of 4, with Back and Use Test Password Only. Otherwise Cancel.
    let inFirstRun: Bool
    let actions: Actions

    public struct Actions {
        public var openPasswords: () -> Void = {}
        public var showGuideStep: (Int) -> Void = { _ in }
        public var notInList: () -> Void = {}
        public var useTestPasswordOnly: () -> Void = {}
        public var back: () -> Void = {}
        public var continueOn: () -> Void = {}
        public var cancel: () -> Void = {}
        public init() {}
    }

    public init(_ state: State, guideStep: Int, earlierVersion: Bool, inFirstRun: Bool, actions: Actions) {
        self.state = state
        self.guideStep = min(max(guideStep, 1), FirstRunCopy.guide.count)
        self.earlierVersion = earlierVersion
        self.inFirstRun = inFirstRun
        self.actions = actions
    }

    private var status: KeyringStatus? {
        switch state {
        case .guide, .waiting: nil
        case .noneArrived: .takingLong(FirstRunCopy.noneArrived)
        case .copying: .waiting(FirstRunCopy.copying)
        case let .copied(count): .done(FirstRunCopy.copied(count))
        case let .failed(reason): .problem(reason)
        }
    }

    private var primary: KeyringAction {
        if case .copied = state { return .advance(FirstRunCopy.continueButton, perform: actions.continueOn) }
        return .advance(FirstRunCopy.openPasswords, isEnabled: state != .copying, perform: actions.openPasswords)
    }

    private var page: some View {
        KeyringPage(step: inFirstRun ? (2, 4) : nil, title: FirstRunCopy.copyTitle, sentence: FirstRunCopy.copyBody, status: status,
                    primary: primary,
                    secondary: inFirstRun ? .plain(FirstRunCopy.back, perform: actions.back) : .plain(FirstRunCopy.cancel, perform: actions.cancel),
                    aside: inFirstRun ? .link(FirstRunCopy.useTestPasswordOnly, perform: actions.useTestPasswordOnly) : nil) {
            VStack(alignment: .leading, spacing: KeyringSpace.s3) {
                KeyringText(FirstRunCopy.guideStep(guideStep), as: .stepMarker)
                KeyringStepRow(guideStep, FirstRunCopy.guide[guideStep - 1]) {
                    if guideStep == 4, earlierVersion { KeyringText(FirstRunCopy.earlierVersion, as: .meta) }
                }
                HStack(spacing: KeyringSpace.s2) {
                    KeyringButton(.plain(FirstRunCopy.previous, isEnabled: guideStep > 1) { actions.showGuideStep(guideStep - 1) })
                    KeyringButton(.plain(FirstRunCopy.next, isEnabled: guideStep < FirstRunCopy.guide.count) { actions.showGuideStep(guideStep + 1) })
                    Spacer(minLength: 0)
                    KeyringButton(.link(FirstRunCopy.notInList, perform: actions.notInList))
                }
            }
        }
    }

    public var body: some View {
        if inFirstRun {
            MacFirstRunWindow(step: 2, mascot: state == .noneArrived ? .waiting : .calm) { page }
        } else {
            page.frame(width: KeyringSize.macWindow.width - KeyringSize.macSidebar, height: KeyringSize.macWindow.height)
        }
    }
}

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

public struct MacConnectAgentPage: View {
    public enum Outcome: Equatable, Sendable {
        case notTried
        case worked(agent: String)
        case denied(agent: String)
    }

    let outcome: Outcome
    let agentNote: String
    let actions: Actions

    public struct Actions {
        public var skipTest: () -> Void = {}
        public var back: () -> Void = {}
        public var continueOn: () -> Void = {}
        public init() {}
    }

    public init(_ outcome: Outcome, agentNote: String = FirstRunCopy.agentNote, actions: Actions) {
        self.outcome = outcome
        self.agentNote = agentNote
        self.actions = actions
    }

    public var body: some View {
        MacFirstRunWindow(step: 3, mascot: outcome == .notTried ? .calm : .approved) {
            KeyringPage(step: (3, 4), title: FirstRunCopy.connectTitle, sentence: FirstRunCopy.connectBody, status: status,
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

public struct MacReadyPage: View {
    /// What Ready says was copied.
    public enum Copied: Equatable, Sendable {
        case passwords(Int)
        case testPasswordOnly
    }

    /// Each row as the members list says now.
    public struct Devices: Equatable, Sendable {
        public var iPhone: String?
        public var watch: String?
        public var computers: [String]
        public init(iPhone: String? = nil, watch: String? = nil, computers: [String] = []) {
            self.iPhone = iPhone
            self.watch = watch
            self.computers = computers
        }
    }

    let copied: Copied
    let devices: Devices
    let actions: Actions

    public struct Actions {
        public var addIPhone: () -> Void = {}
        public var addComputer: () -> Void = {}
        public var showPasswords: () -> Void = {}
        public init() {}
    }

    public init(copied: Copied, devices: Devices, actions: Actions) {
        self.copied = copied
        self.devices = devices
        self.actions = actions
    }

    public var body: some View {
        MacFirstRunWindow(step: 4, mascot: .approved) {
            KeyringPage(step: (4, 4), primary: .advance(FirstRunCopy.showPasswords, perform: actions.showPasswords)) {
                KeyringConfirmation(FirstRunCopy.ready, detail: {
                    switch copied {
                    case let .passwords(count): FirstRunCopy.readyCopied(count)
                    case .testPasswordOnly: FirstRunCopy.readyTestOnly
                    }
                }())
                KeyringText(FirstRunCopy.otherDevices, as: .heading)
                KeyringRowGroup {
                    if let phone = devices.iPhone {
                        KeyringDeviceRow(symbol: "iphone", name: FirstRunCopy.iPhone, detail: FirstRunCopy.added([phone]), tone: .approved)
                    } else {
                        KeyringDeviceRow(symbol: "iphone", name: FirstRunCopy.iPhone, detail: FirstRunCopy.iPhoneDetail) {
                            KeyringButton(.plain(FirstRunCopy.addButton, perform: actions.addIPhone))
                        }
                    }
                    if let watch = devices.watch {
                        KeyringDeviceRow(symbol: "applewatch", name: FirstRunCopy.watch, detail: FirstRunCopy.added([watch]), tone: .approved)
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
