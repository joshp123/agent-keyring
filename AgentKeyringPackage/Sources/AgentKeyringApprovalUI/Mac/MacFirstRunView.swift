// Written by AI on 2026.11.16 by model Claude Opus 5.5; rebuilt on
// 2026.11.18 from the Paper board "First run" (page "First run and the app").
//
// The window Agent Keyring opens on. Before the logins arrive, one step: the
// export, which only Josh can start. Then a list that ticks itself: the
// logins, the test request, and what is left for approving away from the Mac.

#if os(macOS)
import AppKit
import SwiftUI

public struct FirstRunState: Hashable, Sendable {
    public enum Import: Hashable, Sendable {
        /// macOS hasn't yet let Apple Passwords export to Agent Keyring.
        case needsAllow
        case needsExport
        case importing
        /// Apple refused the export extension for this build.
        case blocked
        case done(logins: Int)
    }

    public enum Test: Hashable, Sendable {
        case waiting
        case passed(Date)
        case failed(String)
        /// Denied: a pale ring and Send It Again, since nothing is wrong.
        case declined
    }

    public var imported: Import
    public var test: Test
    public var alwaysOnReady: Bool

    public init(imported: Import, test: Test, alwaysOnReady: Bool) {
        self.imported = imported
        self.test = test
        self.alwaysOnReady = alwaysOnReady
    }
}

public struct MacFirstRunView: View {
    let state: FirstRunState
    let allow: () -> Void
    let openPasswords: () -> Void
    let sendTestAgain: () -> Void
    @State private var didCopy = false

    public init(state: FirstRunState, allow: @escaping () -> Void, openPasswords: @escaping () -> Void,
        sendTestAgain: @escaping () -> Void) {
        self.state = state
        self.allow = allow
        self.openPasswords = openPasswords
        self.sendTestAgain = sendTestAgain
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 20)
            if case let .done(logins) = state.imported {
                if case .passed = state.test { ready } else { EmptyView() }
                Row(mark: .done, title: FirstRunCopy.imported(logins), detail: FirstRunCopy.importedDetail)
                testRow
                if case .passed = state.test { away }
            } else {
                importStep
            }
        }
        .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 14)
        .frame(width: 560, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(RequestToken.surface)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(FirstRunCopy.title).font(.system(size: 22, weight: .bold)).tracking(-0.015 * 22).foregroundStyle(RequestToken.ink)
                Text(FirstRunCopy.intro).font(.system(size: 15)).foregroundStyle(RequestToken.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var importStep: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(FirstRunCopy.importHeading).font(.system(size: 15, weight: .semibold)).foregroundStyle(RequestToken.ink)
            switch state.imported {
            case .needsAllow:
                Detail(FirstRunCopy.allowBody)
                PillButton(title: FirstRunCopy.allowButton, action: allow).padding(.top, 10)
            case .needsExport:
                Detail(FirstRunCopy.exportBody)
                PillButton(title: FirstRunCopy.exportButton, action: openPasswords).padding(.top, 10)
            case .importing:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Detail(FirstRunCopy.importing) }.padding(.top, 6)
            case .blocked, .done:
                Text(FirstRunCopy.blockedBody).font(.system(size: 14)).foregroundStyle(RequestToken.deny)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 18).padding(.bottom, 4)
        .overlay(alignment: .top) { RequestToken.line.frame(height: 1) }
    }

    @ViewBuilder private var testRow: some View {
        switch state.test {
        case .waiting: Row(mark: .working, title: FirstRunCopy.approveTest, detail: FirstRunCopy.approveTestDetail)
        case let .passed(at): Row(mark: .done, title: FirstRunCopy.macWorks, detail: FirstRunCopy.lastTested(at.formatted(date: .omitted, time: .shortened)))
        case let .failed(message): Row(mark: .failed, title: FirstRunCopy.approveTest, detail: message)
        case .declined:
            Row(mark: .notYet, title: FirstRunCopy.notTested, detail: FirstRunCopy.notTestedDenied) {
                PillButton(title: FirstRunCopy.sendAgain, action: sendTestAgain).padding(.top, 10)
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(FirstRunCopy.readyTitle).font(.system(size: 22, weight: .bold)).tracking(-0.015 * 22).foregroundStyle(RequestToken.ink)
            Detail(FirstRunCopy.readyBody)
            HStack(spacing: 8) {
                Keyhole().fill(RequestToken.ink).frame(width: 16, height: 16)
                Text(FirstRunCopy.menuBarHint).font(.system(size: 13)).foregroundStyle(RequestToken.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
        .padding(.vertical, 18)
        .overlay(alignment: .top) { RequestToken.line.frame(height: 1) }
    }

    @ViewBuilder private var away: some View {
        Text(FirstRunCopy.awayHeading).font(.system(size: 12, weight: .semibold)).foregroundStyle(RequestToken.ink2)
            .padding(.top, 18).padding(.bottom, 8)
        if state.alwaysOnReady {
            Row(mark: .done, title: FirstRunCopy.alwaysOn, detail: FirstRunCopy.alwaysOnReady)
        } else {
            Row(mark: .notYet, title: FirstRunCopy.alwaysOn, detail: FirstRunCopy.alwaysOnBody) {
                HStack(spacing: 8) {
                    Text("“\(FirstRunCopy.alwaysOnTask)”").font(.system(size: 14)).foregroundStyle(RequestToken.ink)
                        .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .background(RequestToken.fill, in: .rect(cornerRadius: 10))
                    PillButton(title: didCopy ? FirstRunCopy.copied : FirstRunCopy.copy) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(FirstRunCopy.alwaysOnTask, forType: .string)
                        didCopy = true
                    }
                }
                .padding(.top, 10)
            }
        }
        Row(mark: .notYet, title: FirstRunCopy.phoneAndWatch, detail: FirstRunCopy.phoneAndWatchBody)
    }
}

/// The menu bar's keyhole, as Paper draws it: a circle over a tapering slot.
private struct Keyhole: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 80
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + (x - 10) * s, y: rect.minY + (y - 12) * s) }
        var path = Path(ellipseIn: CGRect(x: rect.minX + (50 - 21.5 - 10) * s, y: rect.minY + (38.5 - 21.5 - 12) * s, width: 43 * s, height: 43 * s))
        path.move(to: p(40.2, 51.5)); path.addLine(to: p(59.8, 51.5)); path.addLine(to: p(67.2, 81.9))
        path.addLine(to: p(64.1, 85.9)); path.addLine(to: p(35.9, 85.9)); path.addLine(to: p(32.8, 81.9)); path.closeSubpath()
        return path
    }
}

private struct Detail: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 14)).foregroundStyle(RequestToken.ink2).fixedSize(horizontal: false, vertical: true)
    }
}

/// A tick, a dark ring (working, or waiting for him), a pale ring (not yet) or a red mark.
private struct Row<Extra: View>: View {
    enum Mark { case done, working, notYet, failed }
    let mark: Mark
    let title: String
    let detail: String
    @ViewBuilder var extra: Extra

    init(mark: Mark, title: String, detail: String, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.mark = mark
        self.title = title
        self.detail = detail
        self.extra = extra()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            symbol.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(mark == .notYet ? RequestToken.ink2 : RequestToken.ink)
                Detail(detail)
                extra
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { RequestToken.line.frame(height: 1) }
    }

    @ViewBuilder private var symbol: some View {
        switch mark {
        case .done:
            Circle().fill(RequestToken.approve).overlay {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(RequestToken.onAnswer)
            }
        case .working: Circle().strokeBorder(RequestToken.ink, lineWidth: 3)
        case .notYet: Circle().strokeBorder(Color(light: 0xC9C9D0, dark: 0x5A5A60), lineWidth: 2)
        case .failed:
            Circle().fill(RequestToken.deny).overlay {
                Image(systemName: "exclamationmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(RequestToken.onAnswer)
            }
        }
    }
}

private struct PillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(RequestToken.surface)
                .padding(.horizontal, 16).frame(height: 32)
                .background(RequestToken.ink, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
#endif
