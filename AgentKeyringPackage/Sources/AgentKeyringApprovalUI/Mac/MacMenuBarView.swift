// Written by AI on 2026.10.31 by model Claude Opus 5.5; unified on 2026.11.26
// by model gemini-4-neon with KeyringUnifiedApprovalCard (460pt popover) and
// the exact same airy 2-line KeyringSettledActivityRow used on iPhone Activity.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import AppKit
import Observation
import SwiftUI

public struct MacMenuBarSnapshot: Hashable, Sendable {
    public var requests: [AccessRequest]
    public var enrolments: [DeviceEnrolment]
    public var passwordCount: Int

    public init(requests: [AccessRequest], enrolments: [DeviceEnrolment] = [], passwordCount: Int = 0) {
        self.requests = requests
        self.enrolments = enrolments
        self.passwordCount = passwordCount
    }
}

@MainActor
public protocol MacMenuBarBackend: AnyObject {
    func menuBarSnapshotUpdates() -> AsyncStream<MacMenuBarSnapshot>
    func endApprovedAccess(requestID: String) async throws -> AccessRequestState
    func allowAskingAgain(requestID: String) async throws -> AccessRequestState
    func approveAccessRequest(requestID: String) async throws -> AccessRequestState
    func denyAccessRequest(requestID: String, reply: String?) async throws -> AccessRequestState
}

@MainActor
@Observable
public final class MacMenuBarModel {
    public private(set) var snapshot: MacMenuBarSnapshot
    public var reviewEnrolment: (String) -> Void = { _ in }
    public var openDevices: () -> Void = {}
    public var openPasswords: () -> Void = {}
    public var openActivity: () -> Void = {}
    public var openSettings: () -> Void = {}
    public var copyAgain: () -> Void = {}
    public var copyAgainShown = true
    public var canCheckForUpdates = false
    public var checkForUpdates: () -> Void = {}
    public var quit: () -> Void = {}
    public private(set) var answeringID: String?
    public private(set) var failure: String?

    private let backend: any MacMenuBarBackend

    public init(backend: any MacMenuBarBackend, initial: MacMenuBarSnapshot) {
        self.snapshot = initial
        self.backend = backend
    }

    public func followUpdates() async {
        for await next in backend.menuBarSnapshotUpdates() { snapshot = next }
    }

    public var waiting: [AccessRequest] { snapshot.requests.filter(\.state.isWaitingForYou) }
    public var earlierToday: [AccessRequest] {
        Array(snapshot.requests.filter { !$0.state.isWaitingForYou && Calendar.current.isDateInToday($0.askedAt) }
            .sorted { $0.askedAt > $1.askedAt }.prefix(4))
    }

    public var waitingCount: Int { waiting.count + snapshot.enrolments.count }

    public func dismissFailure() { failure = nil }

    public func approveAccessRequest(_ id: String) async {
        guard answeringID == nil else { return }
        answeringID = id
        failure = nil
        defer { answeringID = nil }
        do {
            let state = try await backend.approveAccessRequest(requestID: id)
            update(id, to: state)
        } catch is CancellationError {
        } catch {
            failure = ownerAuthenticationFailure(error, fallback: MainWindowCopy.didNotFinish)
        }
    }

    public func denyAccessRequest(_ id: String, reply: String?) async {
        guard answeringID == nil else { return }
        answeringID = id
        failure = nil
        defer { answeringID = nil }
        do {
            let state = try await backend.denyAccessRequest(requestID: id, reply: reply)
            update(id, to: state)
        } catch is CancellationError {
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? MainWindowCopy.didNotFinish
        }
    }

    public func allowAskingAgain(_ id: String) async {
        failure = nil
        do {
            let state = try await backend.allowAskingAgain(requestID: id)
            update(id, to: state)
        } catch is CancellationError {
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? MainWindowCopy.didNotFinish
        }
    }

    private func update(_ id: String, to state: AccessRequestState) {
        guard let index = snapshot.requests.firstIndex(where: { $0.id == id }) else { return }
        snapshot.requests[index].state = state
    }
}

public struct MacMenuBarLabel: View {
    public init() {}

    public var body: some View {
        Image(nsImage: Self.keyhole).accessibilityLabel(SetupCopy.appName)
    }

    static let keyhole: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let s = rect.width / 80
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: (x - 10) * s, y: (y - 12) * s) }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: (50 - 21.5 - 10) * s, y: (38.5 - 21.5 - 12) * s, width: 43 * s, height: 43 * s)).fill()
            let body = NSBezierPath()
            body.move(to: p(40.2, 51.5)); body.line(to: p(59.8, 51.5)); body.line(to: p(67.2, 81.9))
            body.line(to: p(64.1, 85.9)); body.line(to: p(35.9, 85.9)); body.line(to: p(32.8, 81.9)); body.close()
            body.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

public struct MenuBarTipView: View {
    public init() {}

    public var body: some View {
        KeyringText(FirstRunCopy.staysHere, as: .meta, colour: KeyringPalette.ink)
            .fixedSize()
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(KeyringPalette.surface, in: .rect(cornerRadius: 10))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 8)
            .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
            .padding(16)
    }
}

public struct MacMenuBarView: View {
    private enum InlineReplyState: Equatable {
        case idle
        case composing(requestID: String, draft: String)
    }

    let model: MacMenuBarModel
    @State private var inlineReply: InlineReplyState

    public init(model: MacMenuBarModel, initialReplyingRequestID: String? = nil, initialReplyDraft: String = "") {
        self.model = model
        _inlineReply = State(initialValue: initialReplyingRequestID.map { .composing(requestID: $0, draft: initialReplyDraft) } ?? .idle)
    }

    public var body: some View {
        KeyringMenuBarWindow {
            header

            if model.waitingCount > 0 {
                VStack(spacing: KeyringSpace.s3) {
                    ForEach(model.snapshot.enrolments) { enrolment in
                        VStack(alignment: .leading, spacing: KeyringSpace.s3) {
                            KeyringDeviceRow(
                                symbol: enrolment.kind == .machine ? "desktopcomputer" : "iphone",
                                name: enrolment.name,
                                detail: SetupCopy.joiningDetail(enrolment)
                            )
                            HStack(spacing: KeyringSpace.s2) {
                                KeyringButton(.plain(MenuBarCopy.dontAdd) { model.reviewEnrolment(enrolment.id) })
                                KeyringButton(.approve(MenuBarCopy.add, symbol: MacApprover.symbol) { model.reviewEnrolment(enrolment.id) })
                            }
                            .environment(\.keyringButtonsFill, true)
                        }
                        .padding(KeyringSpace.s3 + 2)
                        .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card, style: .continuous).strokeBorder(KeyringPalette.line))
                    }
                    ForEach(model.waiting) { request in
                        waitingCard(request)
                    }
                }
            } else if model.earlierToday.isEmpty {
                KeyringHint(symbol: "checkmark.circle", MenuBarCopy.nothing, tone: .plain)
            }

            if !model.earlierToday.isEmpty {
                VStack(alignment: .leading, spacing: KeyringSpace.s2) {
                    KeyringText(MenuBarCopy.earlierToday, as: .sectionName)
                    VStack(spacing: 0) {
                        ForEach(Array(model.earlierToday.enumerated()), id: \.element.id) { idx, request in
                            if idx > 0 { Divider() }
                            Button {
                                model.openActivity()
                            } label: {
                                KeyringSettledActivityRow(
                                    site: request.login.site,
                                    subtitle: MenuBarCopy.who(request),
                                    time: AccessRequestCopy.clock(request.askedAt),
                                    outcome: Self.outcomeStyle(request),
                                    showChevron: false
                                ) {
                                    SiteIconView(host: request.login.site, size: 22)
                                }
                                .padding(.horizontal, KeyringSpace.s3 + 2)
                                .padding(.vertical, KeyringSpace.s2)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if request.agent.isLocal && request.state.isHoldingOffNewRequests(now: .now) {
                                    Button(MenuBarCopy.letAskAgain) { Task { await model.allowAskingAgain(request.id) } }
                                }
                            }
                        }
                    }
                    .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card, style: .continuous))
                    .clipShape(.rect(cornerRadius: KeyringRadius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card, style: .continuous).strokeBorder(KeyringPalette.line))
                }
            }

            if let failure = model.failure {
                KeyringStatusLine(.problem(failure))
            }

            footer
        }
        .frame(width: KeyringMenuBarWindow<EmptyView>.width)
    }

    private var header: some View {
        HStack(spacing: KeyringSpace.s3) {
            KeyringMascot(model.waitingCount > 0 ? .curious : .calm)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                KeyringText(MenuBarCopy.appName, as: .heading)
                KeyringText(
                    model.waitingCount > 0 ? MenuBarCopy.waiting(model.waitingCount) : MenuBarCopy.allQuiet,
                    as: .meta,
                    colour: model.waitingCount > 0 ? KeyringPalette.brand : KeyringPalette.ink2
                )
            }
            Spacer(minLength: 0)
        }
    }

    private func waitingCard(_ request: AccessRequest) -> some View {
        let isReplying: Bool = if case let .composing(id, _) = inlineReply { id == request.id } else { false }
        let busy = model.answeringID != nil
        let draftBinding = Binding<String>(
            get: { if case let .composing(id, text) = inlineReply, id == request.id { return text }; return "" },
            set: { inlineReply = .composing(requestID: request.id, draft: $0) }
        )
        let approveSymbol = ReviewRendering.isOn
            ? MacApprover.symbol
            : (AccessRequestCopy.approveSymbol(MacApprover.shared.approver) ?? MacApprover.symbol)
        return KeyringUnifiedApprovalCard(
            site: request.login.site,
            account: request.login.account.isEmpty ? nil : request.login.account,
            agent: request.agent.name,
            machine: request.agent.isLocal ? "This Mac" : request.agent.machine,
            reason: request.agentReason.isEmpty ? nil : request.agentReason,
            showBrandBar: false,
            compact: true,
            approve: .approve(MenuBarCopy.approve, symbol: approveSymbol, isEnabled: !busy) {
                Task { await model.approveAccessRequest(request.id) }
            },
            deny: .deny(MenuBarCopy.deny, isEnabled: !busy) {
                Task { await model.denyAccessRequest(request.id, reply: nil) }
            },
            denyAndReply: .denySecondary(MenuBarCopy.denyAndReply, isEnabled: !busy) {
                inlineReply = .composing(requestID: request.id, draft: "")
            },
            replyDraft: isReplying ? draftBinding : nil,
            replyPrompt: MenuBarCopy.replyPrompt,
            onCancelReply: { inlineReply = .idle },
            onSendReply: {
                let text = draftBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                inlineReply = .idle
                Task { await model.denyAccessRequest(request.id, reply: text.isEmpty ? nil : text) }
            },
            sendReplyTitle: MenuBarCopy.sendReply,
            busy: busy
        ) {
            SiteIconView(host: request.login.site, size: 26)
        }
        .padding(KeyringSpace.s3 + 2)
        .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card, style: .continuous).strokeBorder(KeyringPalette.line))
    }

    private var footer: some View {
        HStack(spacing: KeyringSpace.s2) {
            KeyringButton(.plain(MenuBarCopy.activity, perform: model.openActivity))
            KeyringButton(.plain(MenuBarCopy.passwordsTitle, perform: model.openPasswords))
            KeyringButton(.plain(MenuBarCopy.devices, perform: model.openDevices))
            Spacer(minLength: 0)
            Menu {
                if model.copyAgainShown {
                    Button(MenuBarCopy.copyAgain, action: model.copyAgain)
                }
                Button("Settings…", action: model.openSettings)
                Button(MenuBarCopy.checkForUpdates, action: model.checkForUpdates)
                    .disabled(!model.canCheckForUpdates)
                Divider()
                Button(MenuBarCopy.quit, action: model.quit)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(KeyringPalette.ink2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(MenuBarCopy.more)
        }
    }

    /// One consistent outcome word, symbol, and colour across Mac Activity and Mac Menu Bar.
    static func outcomeStyle(_ request: AccessRequest) -> KeyringOutcomeStyle {
        if request.byAutomaticRule {
            return KeyringOutcomeStyle(word: "Auto-approved", symbol: "bolt.circle.fill", colour: KeyringPalette.approve)
        }
        return switch request.state {
        case .approved, .released, .expired:
            KeyringOutcomeStyle(word: MenuBarCopy.approved, symbol: "checkmark.circle.fill", colour: KeyringPalette.approve)
        case .denied:
            KeyringOutcomeStyle(word: MenuBarCopy.denied, symbol: "xmark.circle.fill", colour: KeyringPalette.deny)
        case .blockedByRule:
            KeyringOutcomeStyle(word: MenuBarCopy.blocked, symbol: "nosign", colour: KeyringPalette.deny)
        case .ended:
            KeyringOutcomeStyle(word: MenuBarCopy.stopped, symbol: "stop.circle.fill", colour: KeyringPalette.ink2)
        case .unanswered:
            KeyringOutcomeStyle(word: MenuBarCopy.noAnswer, symbol: "clock", colour: KeyringPalette.ink2)
        case .cancelled:
            KeyringOutcomeStyle(word: MenuBarCopy.cancelled, symbol: "minus.circle", colour: KeyringPalette.ink2)
        case .sendingAnswer, .waitingForMac:
            KeyringOutcomeStyle(word: MenuBarCopy.sending, symbol: "arrow.up.circle", colour: KeyringPalette.ink2)
        case .waitingForYou:
            KeyringOutcomeStyle(word: MenuBarCopy.waitingForYou, symbol: "clock", colour: KeyringPalette.stalled)
        }
    }
}
#endif
