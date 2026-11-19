// Written by AI on 2026.11.16 by model Claude Opus 5.5; rebuilt on
// 2026.11.19 by model claude opus 5.5 from the Paper board "First run"
// (page "First run and the app").
//
// The window Agent Keyring opens on until Josh clicks Done. One screen at a
// time: the export from Passwords; only from its link, the screen before
// macOS's AutoFill question; when the passwords arrive, the practice request;
// after he approves it, the line to give his agents and Done.

#if os(macOS)
import AppKit
import SwiftUI

public enum FirstRunStep: Hashable, Sendable {
    /// Copy from the Passwords app, with the link "Don't see Agent Keyring in Passwords?".
    case export
    /// From that link: one Continue, which raises macOS's AutoFill question.
    case autoFill(canAsk: Bool)
    /// He chose Not Now on macOS's question.
    case autoFillNotNow(canAsk: Bool)
    /// Five minutes after Open Passwords, nothing has arrived.
    case noneArrived
    case copying
    /// The practice request is beside the pointer; `denied` after he denied it.
    case practice(passwords: Int, denied: Bool)
    /// In place of the practice step: Touch ID has no fingerprint and no Apple Watch can approve.
    case needsFingerprint
    /// In place of the practice step: the lid is shut, so Touch ID is off.
    case lidClosed
    case setUp(agentLine: String)
}

public struct MacFirstRunView: View {
    let step: FirstRunStep
    /// An error from the import, shown under the step it blocked.
    let problem: String?
    let openPasswords: () -> Void
    let showAutoFill: () -> Void
    let askForAutoFill: () -> Void
    let tryAgain: () -> Void
    let openTouchIDSettings: () -> Void
    let done: () -> Void

    public init(step: FirstRunStep, problem: String? = nil, openPasswords: @escaping () -> Void = {},
        showAutoFill: @escaping () -> Void = {}, askForAutoFill: @escaping () -> Void = {},
        tryAgain: @escaping () -> Void = {}, openTouchIDSettings: @escaping () -> Void = {}, done: @escaping () -> Void = {}) {
        self.step = step
        self.problem = problem
        self.openPasswords = openPasswords
        self.showAutoFill = showAutoFill
        self.askForAutoFill = askForAutoFill
        self.tryAgain = tryAgain
        self.openTouchIDSettings = openTouchIDSettings
        self.done = done
    }

    public var body: some View {
        VStack(spacing: 22) {
            content
            if let problem {
                Text(problem).font(.system(size: 13)).foregroundStyle(RequestToken.deny)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 36).padding(.top, 14).padding(.bottom, 30)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background(RequestToken.surface)
    }

    /// Paper draws each screen at its own width.
    private var width: CGFloat {
        switch step {
        case .export: 520
        case .setUp: 500
        case .autoFill: 420
        case .autoFillNotNow, .noneArrived, .copying, .practice, .needsFingerprint, .lidClosed: 400
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .export:
            Header(mark: .app(64), title: FirstRunCopy.title, titleSize: 26, sentence: FirstRunCopy.intro)
            Box {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(FirstRunCopy.copyHeading).font(.system(size: 15, weight: .semibold)).foregroundStyle(RequestToken.ink)
                        Text(FirstRunCopy.copyDetail).font(.system(size: 13)).lineSpacing(3).foregroundStyle(RequestToken.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(FirstRunCopy.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(RequestToken.ink)
                                    .frame(width: 20, height: 20).background(RequestToken.surface, in: Circle())
                                Text(step).font(.system(size: 14)).lineSpacing(3).foregroundStyle(RequestToken.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            VStack(spacing: 12) {
                WideButton(title: FirstRunCopy.openPasswords, action: openPasswords)
                Button(action: showAutoFill) {
                    Text(FirstRunCopy.notInList).font(.system(size: 13)).foregroundStyle(RequestToken.brand)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
        case let .autoFill(canAsk):
            Header(mark: .app(44), title: FirstRunCopy.autoFillTitle, titleSize: 20, sentence: FirstRunCopy.autoFillBody)
            WideButton(title: FirstRunCopy.continueButton, action: askForAutoFill).disabled(!canAsk)
        case let .autoFillNotNow(canAsk):
            Sentence(FirstRunCopy.autoFillNotNow)
            WideButton(title: FirstRunCopy.continueButton, action: askForAutoFill).disabled(!canAsk)
        case .noneArrived:
            Sentence(FirstRunCopy.noneArrived)
            WideButton(title: FirstRunCopy.openPasswords, action: openPasswords)
        case .needsFingerprint:
            Sentence(FirstRunCopy.needsFingerprint)
            WideButton(title: FirstRunCopy.openSystemSettings, action: openTouchIDSettings)
        case .lidClosed:
            Sentence(FirstRunCopy.openTheLid)
        case .copying:
            Header(mark: .app(44), title: FirstRunCopy.copying, titleSize: 22, sentence: nil)
            ProgressView().controlSize(.small)
        case let .practice(passwords, denied):
            Header(mark: .app(44), title: FirstRunCopy.copied(passwords), titleSize: 22, sentence: FirstRunCopy.alwaysAsk)
            VStack(spacing: 2) {
                Text(FirstRunCopy.tryPractice).font(.system(size: 15, weight: .semibold)).foregroundStyle(RequestToken.ink)
                Text(denied ? FirstRunCopy.approveOne : FirstRunCopy.approveIt).font(.system(size: 14)).foregroundStyle(RequestToken.ink2)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .overlay(alignment: .top) { RequestToken.line.frame(height: 1) }
            if denied { WideButton(title: FirstRunCopy.tryAgain, action: tryAgain) }
        case let .setUp(agentLine):
            Header(mark: .done, title: FirstRunCopy.setUpTitle, titleSize: 22, sentence: FirstRunCopy.setUpBody)
            Box {
                VStack(alignment: .leading, spacing: 4) {
                    Text(FirstRunCopy.tellAgents).font(.system(size: 15, weight: .semibold)).foregroundStyle(RequestToken.ink)
                    AgentLineBox(caption: FirstRunCopy.tellAgentsBody, line: agentLine)
                }
            }
            WideButton(title: FirstRunCopy.done, action: done)
        }
    }
}

/// The app's mark, or a green tick once he is set up; then a centred title
/// and sentence.
private struct Header: View {
    enum Mark { case app(CGFloat), done }
    let mark: Mark
    let title: String
    let titleSize: CGFloat
    let sentence: String?

    var body: some View {
        VStack(spacing: 14) {
            switch mark {
            case let .app(size): AppMark().frame(width: size, height: size)
            case .done:
                Circle().fill(RequestToken.approve).frame(width: 44, height: 44).overlay {
                    Image(systemName: "checkmark").font(.system(size: 20, weight: .bold)).foregroundStyle(RequestToken.onAnswer)
                }
            }
            VStack(spacing: 6) {
                Text(title).font(.system(size: titleSize, weight: .bold)).tracking(-0.015 * titleSize)
                    .foregroundStyle(RequestToken.ink)
                if let sentence {
                    Text(sentence).font(.system(size: 15)).lineSpacing(3).foregroundStyle(RequestToken.ink2)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Sentence: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 15)).lineSpacing(3).foregroundStyle(RequestToken.ink)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
}

private struct Box<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RequestToken.fill, in: .rect(cornerRadius: 14))
    }
}

/// The line Josh pastes into an agent, with Copy. Also on the Devices tab.
struct AgentLineBox: View {
    let caption: String
    let line: String
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caption).font(.system(size: 13)).lineSpacing(3).foregroundStyle(RequestToken.ink2).fixedSize(horizontal: false, vertical: true)
            Text(line).font(.system(size: 11, design: .monospaced)).lineSpacing(3).foregroundStyle(RequestToken.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
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
    }
}

private struct WideButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(RequestToken.surface)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(RequestToken.ink, in: Capsule())
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}
#endif
