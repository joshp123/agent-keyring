// Written by AI on 2026.11.16 by model Claude Opus 5.5; rebuilt on
// 2026.11.19 by model claude opus 5.5 from the Paper board "First run"
// (page "First run and the app"), one screen per picture.
//
// The window Agent Keyring opens on until he clicks Done. The screen is
// chosen from first run's state (AgentKeyringFeature/FirstRun.swift) and the
// facts beside it; this view only draws it.

#if os(macOS)
import AppKit
import SwiftUI

public enum FirstRunScreen: Equatable, Sendable {
    case welcome
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
    /// `sampleOnly`: the only password is the sample, so a way back to "Copy your passwords" is shown.
    case setUpAgents(copiedTitle: String, copiedDetail: String, sampleOnly: Bool, agents: AgentsButton)
    case ready(phoneLater: Bool, sampleOnly: Bool)
}

/// "Set Up Agents on This Mac", as the window shows it.
public enum AgentsButton: Equatable, Sendable {
    case notYet
    case working
    case done
    case failed(String)
}

public struct FirstRunActions {
    public var getStarted: () -> Void = {}
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
    public var setUpAgents: () -> Void = {}
    public var continueOn: () -> Void = {}
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
    }

    /// Paper draws each window at its own width.
    private var width: CGFloat {
        switch screen {
        case .welcome: 520
        case .practice, .practiceDenied, .needsFingerprint, .lidClosed, .copying: 400
        case .allowExport: 420
        case .copyPasswords: 460
        case .setUpAgents, .ready: 500
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
        case let .setUpAgents(copiedTitle, copiedDetail, sampleOnly, agents):
            HStack(alignment: .top, spacing: 14) {
                Tick(size: 36)
                VStack(alignment: .leading, spacing: 6) {
                    Text(copiedTitle).font(.system(size: 17, weight: .semibold)).foregroundStyle(RequestToken.ink)
                    Para(copiedDetail, size: 14)
                    if sampleOnly { SmallButton(FirstRunCopy.copyOwn, action: actions.copyOwn) }
                }
            }
            .padding(.bottom, 20).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { RequestToken.line.frame(height: 1) }
            VStack(alignment: .leading, spacing: 14) {
                Heading(FirstRunCopy.setUpTitle, FirstRunCopy.setUpBody)
                switch agents {
                case .notYet, .failed: WideButton(FirstRunCopy.setUpAgentsButton, action: actions.setUpAgents)
                case .working: WideButton(FirstRunCopy.setUpAgentsButton, action: {}).disabled(true)
                case .done:
                    HStack(spacing: 10) {
                        Tick(size: 20)
                        Text(FirstRunCopy.agentsSetUp).font(.system(size: 14, weight: .semibold)).foregroundStyle(RequestToken.ink)
                    }
                }
                if case let .failed(message) = agents {
                    Text(message).font(.system(size: 13)).lineSpacing(3).foregroundStyle(RequestToken.deny).fixedSize(horizontal: false, vertical: true)
                }
                Small(FirstRunCopy.setUpAgentsNote)
            }
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(FirstRunCopy.otherDevicesTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(RequestToken.ink)
                    Para(FirstRunCopy.otherDevicesBody, size: 14)
                }
                AgentLineBox(caption: nil, line: FirstRunCopy.agentLine, copyTitle: FirstRunCopy.copyMessage, quiet: true)
            }
            .padding(.top, 20).overlay(alignment: .top) { RequestToken.line.frame(height: 1) }
            if case .done = agents {
                WideButton(FirstRunCopy.continueButton, action: actions.continueOn)
            } else {
                WideButton(FirstRunCopy.continueButton, quiet: true, action: {}).disabled(true)
            }
        case let .ready(phoneLater, sampleOnly):
            VStack(spacing: 14) {
                Tick(size: 44)
                Text(FirstRunCopy.ready).font(.system(size: 22, weight: .bold)).tracking(-0.33).foregroundStyle(RequestToken.ink)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 18) {
                if sampleOnly {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 20)).foregroundStyle(RequestToken.ink2).frame(width: 46)
                        VStack(alignment: .leading, spacing: 10) {
                            Point(title: FirstRunCopy.sampleTitle, detail: FirstRunCopy.sampleBody)
                            SmallButton(FirstRunCopy.copyOwn, onFill: false, action: actions.copyOwn)
                        }
                    }
                    .padding(.vertical, 14).padding(.trailing, 16)
                    .background(RequestToken.fill, in: .rect(cornerRadius: 12))
                }
                Points(FirstRunCopy.readyPoints.map { ($0.symbol, $0.title, $0.body) }
                    + [phoneLater ? ("iphone", FirstRunCopy.phoneLaterTitle, FirstRunCopy.phoneLaterBody)
                                  : ("iphone", FirstRunCopy.phoneTitle, FirstRunCopy.phoneBody)])
            }
            WideButton(FirstRunCopy.done, action: actions.done)
        }
    }
}

/// A small grey pill (white on a grey box), as Paper draws "Copy Your Own Passwords" and "Copy Message".
private struct SmallButton: View {
    let title: String
    var onFill = true
    let action: () -> Void
    init(_ title: String, onFill: Bool = true, action: @escaping () -> Void) { self.title = title; self.onFill = onFill; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(RequestToken.ink)
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
    init(_ title: String, _ sentence: String) { self.title = title; self.sentence = sentence }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .bold)).tracking(-0.33).foregroundStyle(RequestToken.ink)
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
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 13)).lineSpacing(3).foregroundStyle(RequestToken.ink2).fixedSize(horizontal: false, vertical: true)
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

/// The message Josh sends an agent, with its copy button. Also on the Devices tab.
struct AgentLineBox: View {
    let caption: String?
    let line: String
    var copyTitle = FirstRunCopy.copy
    /// A white button on the grey box, as on "Set up your agents"; else black.
    var quiet = false
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let caption {
                Text(caption).font(.system(size: 13)).lineSpacing(3).foregroundStyle(RequestToken.ink2).fixedSize(horizontal: false, vertical: true)
            }
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
                    Text(didCopy ? FirstRunCopy.copied : copyTitle).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(quiet ? RequestToken.ink : RequestToken.surface)
                        .padding(.horizontal, 16).frame(height: 30)
                        .background(quiet ? RequestToken.surface : RequestToken.ink, in: Capsule())
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
