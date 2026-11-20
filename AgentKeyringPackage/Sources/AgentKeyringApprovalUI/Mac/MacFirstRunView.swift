// Written by AI on 2026.11.16 by model Claude Opus 5.5; rebuilt on
// 2026.11.19 and again on 2026.11.20 by model claude opus 5.5 from the Paper
// board "Mac" (page "First run and the app"), one window per step.
//
// The window Agent Keyring opens on until he clicks Done. The screen is
// chosen from first run's state (AgentKeyringFeature/FirstRun.swift) and the
// facts beside it; this view only draws it.

#if os(macOS)
import AppKit
import SwiftUI

public enum FirstRunScreen: Equatable, Sendable {
    case welcome
    /// "Which devices do you want to use?" Interim until the board is drawn.
    case chooseDevices
    case practice
    case practiceDenied(reply: String)
    /// In place of the practice request: Touch ID has no fingerprint.
    case needsFingerprint
    /// In place of the practice request: the lid is closed.
    case lidClosed
    /// From first run, with the sample password offered; from the main window, with Cancel.
    /// `earlierVersion`: 0.2.5 is on this Mac, so Passwords' list has two names alike.
    case copyPasswords(waiting: Bool, noneArrived: Bool, offerSample: Bool, earlierVersion: Bool)
    /// "Agent Keyring isn't in the list?"; `asking` while macOS's AutoFill question is up.
    case allowExport(asking: Bool)
    case copying
    /// "Tell your agents". `header` is what was copied (none in the sheet from
    /// Devices); `approved` is the first request he approved, once there is one.
    case tellAgents(header: CopiedHeader?, approved: String?)
    /// "Approve from your iPhone and Apple Watch": the address of a computer that stays on.
    /// `offered`: the computer that stays on which announced itself, by name.
    case stayingOn(failure: String?, offered: String? = nil)
    /// After Connect, while macOS asks for Touch ID.
    case connecting(name: String)
    /// `added`: the iPhone's name once it has joined.
    case addPhone(added: String?)
    case addWatch(added: String?)
    /// `command` is made when the window opens; `joined` names the computers that have joined.
    case addComputers(command: String?, joined: [String])
    case tryDevices([PracticeRow])
    /// `alone`: no iPhone or Apple Watch added.
    case ready(alone: Bool, sampleOnly: Bool)
}

/// The line at the top of "Tell your agents": what was copied.
public struct CopiedHeader: Equatable, Sendable {
    public let title: String
    public let detail: String
    /// The sample: Copy Your Own Passwords sits beside it.
    public let sample: Bool
    public init(title: String, detail: String, sample: Bool) { self.title = title; self.detail = detail; self.sample = sample }
}

/// One device on "Try a request on each device" and in Devices.
public struct PracticeRow: Identifiable, Hashable, Sendable {
    public enum Tone: Hashable, Sendable { case plain, approved, denied }
    public let id: String
    public let name: String
    public let symbol: String
    public let detail: String
    public let tone: Tone
    /// False while a practice request to it is waiting.
    public let canSend: Bool
    public init(id: String, name: String, symbol: String, detail: String, tone: Tone, canSend: Bool) {
        self.id = id; self.name = name; self.symbol = symbol; self.detail = detail; self.tone = tone; self.canSend = canSend
    }
}

public struct FirstRunActions {
    public var getStarted: () -> Void = {}
    /// iPhone, Apple Watch, other computers.
    public var chooseDevices: (Bool, Bool, Bool) -> Void = { _, _, _ in }
    public var tryAgain: () -> Void = {}
    public var openTouchIDSettings: () -> Void = {}
    public var openPasswords: () -> Void = {}
    public var useSample: () -> Void = {}
    /// From the sample, back to "Copy your passwords".
    public var copyOwn: () -> Void = {}
    /// Leaves "Copy your passwords" opened from the main window.
    public var cancelCopy: () -> Void = {}
    public var notInList: () -> Void = {}
    public var allowExport: () -> Void = {}
    public var continueOn: () -> Void = {}
    public var skip: () -> Void = {}
    /// Connect, with the address he typed.
    public var connect: (String) -> Void = { _ in }
    public var useThisMacAlone: () -> Void = {}
    /// "Connect to Mac mini?": the computer that announced itself, after Touch ID.
    public var connectOffered: () -> Void = {}
    /// Send Practice Request, with the device's key.
    public var sendPractice: (String) -> Void = { _ in }
    public var done: () -> Void = {}
    public init() {}
}

public struct MacFirstRunView: View {
    let screen: FirstRunScreen
    /// An error from the import, shown under the step it blocked.
    let problem: String?
    let actions: FirstRunActions

    public init(screen: FirstRunScreen, problem: String? = nil, actions: FirstRunActions = FirstRunActions()) {
        self.screen = screen
        self.problem = problem
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            content
            if let problem {
                Text(problem).font(.system(size: 13)).foregroundStyle(RequestToken.deny).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, horizontalPadding).padding(.top, 6).padding(.bottom, 30)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(RequestToken.surface)
        // The first click on a button works even while another app is in front.
        .allowsWindowActivationEvents(true)
    }

    /// Paper draws each window at its own width.
    private var width: CGFloat {
        switch screen {
        case .welcome, .stayingOn: 520
        case .chooseDevices: 460
        case .practice, .practiceDenied, .needsFingerprint, .lidClosed, .copying: 400
        case .connecting: 360
        case .allowExport: 420
        case .copyPasswords: 460
        case .tellAgents, .addPhone, .addWatch, .addComputers, .tryDevices, .ready: 500
        }
    }

    private var horizontalPadding: CGFloat {
        switch screen {
        case .welcome, .ready: 40
        default: 36
        }
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .welcome:
            VStack(spacing: 14) {
                AppMark().frame(width: 64, height: 64)
                VStack(spacing: 8) {
                    Text(FirstRunCopy.title).font(.system(size: 26, weight: .bold)).tracking(-0.39).foregroundStyle(RequestToken.ink)
                    Para(FirstRunCopy.intro, size: 15).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            Points(FirstRunCopy.points.map { ($0.symbol, $0.title, $0.body) })
            WideButton(FirstRunCopy.getStarted, action: actions.getStarted)
        case .chooseDevices:
            ChooseDevices(choose: actions.chooseDevices)
        case .practice:
            Heading(FirstRunCopy.tryPractice, FirstRunCopy.practiceIntro)
            VStack(alignment: .leading, spacing: 12) {
                Dot(RequestToken.approve, FirstRunCopy.toApprove)
                Dot(RequestToken.deny, FirstRunCopy.toDeny)
            }
            .padding(.top, 18).overlay(alignment: .top) { RequestToken.line.frame(height: 1) }
            Small(FirstRunCopy.approveToContinue)
        case let .practiceDenied(reply):
            Heading(FirstRunCopy.youDeniedIt, reply.isEmpty ? FirstRunCopy.realAgentWouldStop : FirstRunCopy.realAgentWouldRead)
            if !reply.isEmpty {
                Text("“\(reply)”").font(.system(size: 15)).lineSpacing(3).foregroundStyle(RequestToken.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RequestToken.fill, in: .rect(cornerRadius: 12))
            }
            Small(FirstRunCopy.approveOneToContinue)
            WideButton(FirstRunCopy.tryAgain, action: actions.tryAgain)
        case .needsFingerprint:
            Heading(FirstRunCopy.addFingerprint, FirstRunCopy.addFingerprintBody)
            WideButton(FirstRunCopy.openTouchIDSettings, action: actions.openTouchIDSettings)
        case .lidClosed:
            Heading(FirstRunCopy.openTheLid, FirstRunCopy.openTheLidBody)
        case let .copyPasswords(waiting, noneArrived, offerSample, earlierVersion):
            Heading(FirstRunCopy.copyTitle, FirstRunCopy.copyBody)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(FirstRunCopy.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(RequestToken.ink)
                            .frame(width: 20, height: 20).background(RequestToken.surface, in: Circle())
                        VStack(alignment: .leading, spacing: 8) {
                            Text(LocalizedStringKey(step)).font(.system(size: 14)).lineSpacing(2).foregroundStyle(RequestToken.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if index == FirstRunCopy.steps.count - 1 {
                                // This app as Passwords' list shows it, so he picks it by its icon.
                                HStack(spacing: 8) {
                                    AppMark().frame(width: 20, height: 20)
                                    Text(FirstRunCopy.appName).font(.system(size: 14, weight: .semibold)).foregroundStyle(RequestToken.ink)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RequestToken.surface, in: .rect(cornerRadius: 8))
                                if earlierVersion { Small(FirstRunCopy.earlierVersion) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button(action: actions.notInList) {
                    Text(FirstRunCopy.notInList).font(.system(size: 13)).foregroundStyle(RequestToken.brand)
                }
                .buttonStyle(.plain).padding(.leading, 30).padding(.top, 2)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .background(RequestToken.fill, in: .rect(cornerRadius: 14))
            if noneArrived {
                Text(FirstRunCopy.noneArrived).font(.system(size: 13)).foregroundStyle(RequestToken.deny).fixedSize(horizontal: false, vertical: true)
            } else {
                Small(FirstRunCopy.deletesNothing)
            }
            VStack(spacing: 14) {
                if waiting { Waiting(FirstRunCopy.waitingForPasswords).frame(maxWidth: .infinity) }
                WideButton(FirstRunCopy.openPasswords, action: actions.openPasswords)
            }
            if offerSample {
                VStack(spacing: 8) {
                    WideButton(FirstRunCopy.useSample, quiet: true, action: actions.useSample)
                    Small(FirstRunCopy.sampleNote).multilineTextAlignment(.center)
                }
            } else {
                WideButton(FirstRunCopy.cancel, quiet: true, action: actions.cancelCopy)
            }
        case let .allowExport(asking):
            VStack(spacing: 14) {
                AppMark().frame(width: 44, height: 44)
                VStack(spacing: 6) {
                    Text(FirstRunCopy.allowExportTitle).font(.system(size: 20, weight: .bold)).tracking(-0.3).foregroundStyle(RequestToken.ink)
                    Para(FirstRunCopy.allowExportBody, size: 15).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            WideButton(FirstRunCopy.continueButton, action: actions.allowExport).disabled(asking)
        case .copying:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(FirstRunCopy.copying).font(.system(size: 15)).foregroundStyle(RequestToken.ink)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 40)
        case let .tellAgents(header, approved):
            if let header {
                HStack(spacing: 12) {
                    Tick(size: 28)
                    (Text(header.title + " ").fontWeight(.semibold) + Text(header.detail))
                        .font(.system(size: 14)).lineSpacing(2).foregroundStyle(RequestToken.ink)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    if header.sample { SmallButton(FirstRunCopy.copyOwn, action: actions.copyOwn) }
                }
                .padding(.bottom, 18).overlay(alignment: .bottom) { RequestToken.line.frame(height: 1) }
            }
            Heading(FirstRunCopy.tellTitle, FirstRunCopy.tellBody)
            AgentLineBox(line: FirstRunCopy.agentNote)
            Small(FirstRunCopy.pasteIt, size: 14)
            if header != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text(FirstRunCopy.tryItNow).font(.system(size: 15, weight: .semibold)).foregroundStyle(RequestToken.ink)
                    Small(header?.sample == true ? FirstRunCopy.tryItSample : FirstRunCopy.tryItBody, size: 14)
                    if let approved {
                        HStack(spacing: 10) {
                            Tick(size: 16)
                            Text(approved).font(.system(size: 14)).foregroundStyle(RequestToken.ink)
                        }
                        .padding(.top, 4)
                    } else {
                        Waiting(FirstRunCopy.noRequestYet).padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 18).overlay(alignment: .top) { RequestToken.line.frame(height: 1) }
            }
            WideButton(FirstRunCopy.continueButton, action: actions.continueOn)
        case let .stayingOn(failure, offered):
            Heading(FirstRunCopy.stayingOnTitle, FirstRunCopy.stayingOnBody)
            if let offered {
                WideButton(FirstRunCopy.connectTo(offered), action: actions.connectOffered)
            }
            AddressEntry(failure: failure, connect: actions.connect)
            VStack(alignment: .leading, spacing: 14) {
                Point(title: FirstRunCopy.isThisMacTitle, detail: FirstRunCopy.isThisMacBody)
                Point(title: FirstRunCopy.noneStaysOnTitle, detail: FirstRunCopy.noneStaysOnBody)
            }
            .padding(.top, 20).overlay(alignment: .top) { RequestToken.line.frame(height: 1) }
            WideButton(FirstRunCopy.useThisMacAlone, quiet: true, action: actions.useThisMacAlone)
        case let .connecting(name):
            Heading(FirstRunCopy.approveComputer(name), FirstRunCopy.approveInDialog, size: 22)
            Waiting(FirstRunCopy.waitingForApproval)
        case let .addPhone(added):
            Heading(FirstRunCopy.phoneTitle, FirstRunCopy.phoneBody)
            NumberedSteps(FirstRunCopy.phoneSteps)
            Joining(waiting: FirstRunCopy.waitingForPhone, joined: added.map(FirstRunCopy.added))
            WideButton(added == nil ? FirstRunCopy.skip : FirstRunCopy.continueButton, quiet: added == nil,
                action: added == nil ? actions.skip : actions.continueOn)
        case let .addWatch(added):
            Heading(FirstRunCopy.watchTitle, FirstRunCopy.watchBody)
            NumberedSteps(FirstRunCopy.watchSteps)
            Joining(waiting: FirstRunCopy.waitingForWatch, joined: added.map(FirstRunCopy.added))
            WideButton(added == nil ? FirstRunCopy.skip : FirstRunCopy.continueButton, quiet: added == nil,
                action: added == nil ? actions.skip : actions.continueOn)
        case let .addComputers(command, joined):
            Heading(FirstRunCopy.computersTitle, FirstRunCopy.computersBody)
            CommandBox(command: command)
            if !joined.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(joined, id: \.self) { name in
                        HStack(spacing: 10) {
                            Tick(size: 16)
                            Text(FirstRunCopy.joined(name)).font(.system(size: 14)).foregroundStyle(RequestToken.ink)
                        }
                    }
                }
            }
            WideButton(FirstRunCopy.continueButton, quiet: true, action: actions.continueOn)
        case let .tryDevices(rows):
            Heading(FirstRunCopy.tryTitle, FirstRunCopy.tryBody)
            PracticeRows(rows: rows, send: actions.sendPractice)
            WideButton(FirstRunCopy.continueButton, action: actions.continueOn)
        case let .ready(alone, sampleOnly):
            VStack(spacing: 14) {
                if !sampleOnly { Tick(size: 44) }
                Text(FirstRunCopy.ready).font(.system(size: 22, weight: .bold)).tracking(-0.33).foregroundStyle(RequestToken.ink)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 18) {
                if sampleOnly {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "info.circle").font(.system(size: 20)).foregroundStyle(RequestToken.ink2).frame(width: 46)
                        VStack(alignment: .leading, spacing: 10) {
                            Point(title: FirstRunCopy.sampleTitle, detail: FirstRunCopy.sampleBody)
                            SmallButton(FirstRunCopy.copyOwn, onFill: false, action: actions.copyOwn)
                        }
                    }
                    .padding(.vertical, 14).padding(.trailing, 16)
                    .background(RequestToken.fill, in: .rect(cornerRadius: 12))
                }
                Points((alone ? FirstRunCopy.readyAlonePoints : FirstRunCopy.readyPoints).map { ($0.symbol, $0.title, $0.body) })
            }
            WideButton(FirstRunCopy.done, action: actions.done)
        }
    }
}

/// "Its address", the field and Connect, and the error under them if Connect failed.
private struct AddressEntry: View {
    let failure: String?
    let connect: (String) -> Void
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(FirstRunCopy.itsAddress).font(.system(size: 12, weight: .semibold)).foregroundStyle(RequestToken.ink2)
            HStack(spacing: 8) {
                TextField(FirstRunCopy.addressPlaceholder, text: $address)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(RequestToken.surface, in: .rect(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(RequestToken.line) }
                    .onSubmit { connect(address) }
                DarkPill(FirstRunCopy.connect) { connect(address) }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let failure {
                Text(failure).font(.system(size: 13)).foregroundStyle(RequestToken.deny).fixedSize(horizontal: false, vertical: true)
            } else {
                Small(FirstRunCopy.addressHint)
            }
        }
    }
}

/// The one-time command, with its two copy buttons and the note under them.
private struct CommandBox: View {
    let command: String?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(command ?? " ").font(.system(size: 13, design: .monospaced)).lineSpacing(3).foregroundStyle(RequestToken.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RequestToken.surface, in: .rect(cornerRadius: 8))
            HStack(spacing: 8) {
                Spacer()
                SmallButton(copied == "prompt" ? FirstRunCopy.copied : FirstRunCopy.copyPrompt, onFill: false) {
                    copy(FirstRunCopy.enrolPrompt(command ?? ""), as: "prompt")
                }
                DarkPill(copied == "command" ? FirstRunCopy.copied : FirstRunCopy.copyCommand) { copy(command ?? "", as: "command") }
            }
            .disabled(command == nil)
            Small(FirstRunCopy.commandNote)
        }
        .padding(14)
        .background(RequestToken.fill, in: .rect(cornerRadius: 14))
    }

    private func copy(_ text: String, as kind: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = kind
    }
}

/// One row per device he answers on, each with Send Practice Request and its last result.
struct PracticeRows: View {
    let rows: [PracticeRow]
    let send: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack(spacing: 14) {
                    Image(systemName: row.symbol).font(.system(size: 15)).foregroundStyle(RequestToken.ink).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(RequestToken.ink)
                        Text(row.detail).font(.system(size: 13))
                            .foregroundStyle(row.tone == .approved ? RequestToken.approve : row.tone == .denied ? RequestToken.deny : RequestToken.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    SmallButton(FirstRunCopy.sendPractice) { send(row.id) }.disabled(!row.canSend)
                }
                .padding(.vertical, 12)
                .overlay(alignment: .top) { RequestToken.line.frame(height: 1) }
            }
        }
        .overlay(alignment: .bottom) { RequestToken.line.frame(height: 1) }
    }
}

/// Numbered steps on a grey box, as "Add your iPhone" and "Add your Apple Watch" draw them.
private struct NumberedSteps: View {
    let steps: [String]
    init(_ steps: [String]) { self.steps = steps }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(RequestToken.ink)
                        .frame(width: 20, height: 20).background(RequestToken.surface, in: Circle())
                    Text(step).font(.system(size: 14)).lineSpacing(2).foregroundStyle(RequestToken.ink)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(RequestToken.fill, in: .rect(cornerRadius: 14))
    }
}

/// "Waiting for your iPhone", or a tick and "Josh's iPhone added." once it has joined.
private struct Joining: View {
    let waiting: String
    let joined: String?
    var body: some View {
        if let joined {
            HStack(spacing: 10) {
                Tick(size: 16)
                Text(joined).font(.system(size: 14)).foregroundStyle(RequestToken.ink)
            }
        } else {
            Waiting(waiting)
        }
    }
}

/// A black pill, as "Connect" and "Copy Command" are drawn.
private struct DarkPill: View {
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(RequestToken.surface)
                .padding(.horizontal, 16).frame(height: 30)
                .background(RequestToken.ink, in: Capsule()).contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain).fixedSize()
    }
}

/// Interim until the board is drawn: the devices he will use beside this Mac.
private struct ChooseDevices: View {
    let choose: (Bool, Bool, Bool) -> Void
    @State private var iPhone = true
    @State private var watch = true
    @State private var computers = false
    var body: some View {
        Heading(FirstRunCopy.chooseTitle, FirstRunCopy.chooseBody)
        VStack(alignment: .leading, spacing: 10) {
            Toggle(FirstRunCopy.chooseIPhone, isOn: $iPhone)
            Toggle(FirstRunCopy.chooseWatch, isOn: $watch)
            Toggle(FirstRunCopy.chooseComputers, isOn: $computers)
        }
        .toggleStyle(.checkbox).font(.system(size: 14))
        WideButton(FirstRunCopy.continueButton) { choose(iPhone, watch, computers) }
    }
}

/// A small grey pill (white on a grey box), as Paper draws "Copy Your Own Passwords" and "Copy Message".
struct SmallButton: View {
    let title: String
    var onFill = true
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    init(_ title: String, onFill: Bool = true, action: @escaping () -> Void) { self.title = title; self.onFill = onFill; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(isEnabled ? RequestToken.ink : RequestToken.ink2)
                .padding(.horizontal, 14).frame(height: 30)
                .background(onFill ? RequestToken.fill : RequestToken.surface, in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize()
    }
}

/// A bold title and the sentence under it, left-aligned.
private struct Heading: View {
    let title: String
    let sentence: String
    let size: CGFloat
    init(_ title: String, _ sentence: String, size: CGFloat = 22) { self.title = title; self.sentence = sentence; self.size = size }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: size, weight: .bold)).tracking(-0.33).foregroundStyle(RequestToken.ink)
            Para(sentence, size: 15)
        }
    }
}

private struct Para: View {
    let text: String
    let size: CGFloat
    init(_ text: String, size: CGFloat) { self.text = text; self.size = size }
    var body: some View {
        Text(text).font(.system(size: size)).lineSpacing(3).foregroundStyle(RequestToken.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Small: View {
    let text: String
    let size: CGFloat
    init(_ text: String, size: CGFloat = 13) { self.text = text; self.size = size }
    var body: some View {
        Text(text).font(.system(size: size)).lineSpacing(3).foregroundStyle(RequestToken.ink2).fixedSize(horizontal: false, vertical: true)
    }
}

private struct Dot: View {
    let colour: Color
    let text: String
    init(_ colour: Color, _ text: String) { self.colour = colour; self.text = text }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(colour).frame(width: 10, height: 10).padding(.top, 5)
            Text(text).font(.system(size: 14)).lineSpacing(3).foregroundStyle(RequestToken.ink).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Waiting: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small).frame(width: 16, height: 18)
            Text(text).font(.system(size: 14)).lineSpacing(3).foregroundStyle(RequestToken.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Tick: View {
    let size: CGFloat
    var body: some View {
        Circle().fill(RequestToken.approve).frame(width: size, height: size).overlay {
            Image(systemName: "checkmark").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(RequestToken.onAnswer)
        }
    }
}

/// The blue symbol, then a bold line and its sentence (Paper's welcome and Ready lists).
private struct Points: View {
    let items: [(symbol: String, title: String, body: String)]
    init(_ items: [(symbol: String, title: String, body: String)]) { self.items = items }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 14) {
                    Group {
                        if item.symbol == "keyhole" { Keyhole().fill(RequestToken.brand).frame(width: 14, height: 19) }
                        else { Image(systemName: item.symbol).font(.system(size: 20)).foregroundStyle(RequestToken.brand) }
                    }
                    .frame(width: 32).padding(.top, 1)
                    Point(title: item.title, detail: item.body)
                }
            }
        }
    }
}

private struct Point: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(RequestToken.ink)
            Text(detail).font(.system(size: 14)).lineSpacing(3).foregroundStyle(RequestToken.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The note he gives his agents, with its Copy button.
private struct AgentLineBox: View {
    let line: String
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(line).font(.system(size: 14)).lineSpacing(3).foregroundStyle(RequestToken.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RequestToken.surface, in: .rect(cornerRadius: 8))
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(line, forType: .string)
                    didCopy = true
                } label: {
                    Text(didCopy ? FirstRunCopy.copied : FirstRunCopy.copy).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RequestToken.surface)
                        .padding(.horizontal, 16).frame(height: 30)
                        .background(RequestToken.ink, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RequestToken.fill, in: .rect(cornerRadius: 14))
    }
}

private struct WideButton: View {
    let title: String
    var quiet = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, quiet: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.quiet = quiet
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(quiet ? RequestToken.ink : RequestToken.surface)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(quiet ? RequestToken.fill : RequestToken.ink, in: Capsule())
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}
/// The menu bar's keyhole, as Paper draws it beside "Agent Keyring stays in the menu bar".
private struct Keyhole: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = rect.width * 0.5
        path.addEllipse(in: CGRect(x: rect.midX - r, y: rect.minY, width: 2 * r, height: 2 * r))
        path.move(to: CGPoint(x: rect.midX - r * 0.45, y: rect.minY + 1.6 * r))
        path.addLine(to: CGPoint(x: rect.midX + r * 0.45, y: rect.minY + 1.6 * r))
        path.addLine(to: CGPoint(x: rect.midX + r * 0.8, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - r * 0.8, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
#endif
