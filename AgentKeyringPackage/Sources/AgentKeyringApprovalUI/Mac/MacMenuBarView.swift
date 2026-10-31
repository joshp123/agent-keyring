// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The menu bar window: what is waiting, what agents are using now with a
// way to end it, and the last few answers. Two ways out: the rules, and the
// app. Nothing else, because nothing else is needed often.

#if os(macOS)
import Observation
import SwiftUI

public struct ImportedPasswords: Hashable, Sendable {
    public var count: Int
    public var importedAt: Date

    public init(count: Int, importedAt: Date) {
        self.count = count
        self.importedAt = importedAt
    }
}

public struct MacMenuBarSnapshot: Hashable, Sendable {
    /// Waiting, in use and recent requests, in any order.
    public var requests: [AccessRequest]
    public var passwords: ImportedPasswords?

    public init(requests: [AccessRequest], passwords: ImportedPasswords?) {
        self.requests = requests
        self.passwords = passwords
    }
}

@MainActor
public protocol MacMenuBarBackend: AnyObject {
    /// The current snapshot first, then one each time anything changes.
    func updates() -> AsyncStream<MacMenuBarSnapshot>
    /// Josh ends an agent's access early. The lease becomes REVOKED.
    func endAccess(requestID: String) async throws -> AccessRequestState
    /// Clears a denial's hold-off, so that machine may ask for the login again.
    func allowAskingAgain(requestID: String) async throws -> AccessRequestState
}

@MainActor
@Observable
public final class MacMenuBarModel {
    public private(set) var requests: [AccessRequest]
    public private(set) var passwords: ImportedPasswords?
    public var review: (String) -> Void = { _ in }
    public var openRules: () -> Void = {}
    public var openAgentKeyring: () -> Void = {}
    public var checkForUpdates: () -> Void = {}
    public var quit: () -> Void = {}

    private let backend: any MacMenuBarBackend

    public init(backend: any MacMenuBarBackend, initial: MacMenuBarSnapshot) {
        self.requests = initial.requests
        self.passwords = initial.passwords
        self.backend = backend
    }

    /// Follows the backend for as long as the app runs. Start it once at launch,
    /// not from the window, because the menu bar icon shows the waiting count.
    public func followUpdates() async {
        for await snapshot in backend.updates() {
            requests = snapshot.requests
            passwords = snapshot.passwords
        }
    }

    public var waiting: [AccessRequest] { requests.filter(\.state.isWaitingForYou) }
    public var inUse: [AccessRequest] { requests.filter(\.state.isInUse) }
    public var recent: [AccessRequest] {
        Array(requests.filter { !$0.state.isWaitingForYou && !$0.state.isInUse }
            .sorted { $0.askedAt > $1.askedAt }.prefix(4))
    }

    public func endAccess(_ id: String) async {
        guard let state = try? await backend.endAccess(requestID: id) else { return }
        update(id, to: state)
    }

    public func allowAskingAgain(_ id: String) async {
        guard let state = try? await backend.allowAskingAgain(requestID: id) else { return }
        update(id, to: state)
    }

    private func update(_ id: String, to state: AccessRequestState) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].state = state
    }
}

/// The icon in the menu bar. Shows how many requests wait, so a waiting
/// request is visible without opening anything.
public struct MacMenuBarLabel: View {
    let waitingCount: Int

    public init(waitingCount: Int) {
        self.waitingCount = waitingCount
    }

    public var body: some View {
        if waitingCount > 0 {
            Label("\(waitingCount)", systemImage: "key.horizontal.fill")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "key.horizontal")
                .accessibilityLabel("Agent Keyring")
        }
    }
}

public struct MacMenuBarView: View {
    let model: MacMenuBarModel

    public init(model: MacMenuBarModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.waiting.isEmpty {
                MenuSection(title: "Waiting for you") {
                    ForEach(model.waiting) { request in
                        WaitingMenuRow(request: request) { model.review(request.id) }
                    }
                }
            }
            if !model.inUse.isEmpty {
                MenuSection(title: "In use now") {
                    ForEach(model.inUse) { request in
                        InUseMenuRow(request: request) { Task { await model.endAccess(request.id) } }
                    }
                }
            }
            if model.waiting.isEmpty && model.inUse.isEmpty {
                Text("No agent is using a login now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            if !model.recent.isEmpty {
                MenuSection(title: "Recent") {
                    ForEach(model.recent) { request in
                        RecentMenuRow(request: request) { Task { await model.allowAskingAgain(request.id) } }
                    }
                }
            }
            Divider().padding(.top, 6)
            footer
        }
        .padding(.vertical, 6)
        .frame(width: 340)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let passwords = model.passwords {
                Text("\(passwords.count) logins · imported \(passwords.importedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Rules…", action: model.openRules)
                .controlSize(.small)
                .accessibilityIdentifier("menu-rules")
            Menu {
                Button("Open Agent Keyring", action: model.openAgentKeyring)
                Button("Check for Updates…", action: model.checkForUpdates)
                Divider()
                Button("Quit Agent Keyring", action: model.quit)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("More")
            .accessibilityIdentifier("menu-more")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

private struct MenuSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 2)
            content
        }
    }
}

private struct WaitingMenuRow: View {
    let request: AccessRequest
    let review: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(KeyringColour.signal).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.login.site).font(.body.weight(.semibold))
                Text("\(request.agent.name) · \(AccessRequestCopy.origin(request.agent))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if case let .waitingForYou(until) = request.state {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(AccessRequestCopy.remaining(until: until, now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(KeyringColour.signal)
                }
            }
            Button("Review", action: review)
                .buttonStyle(.borderedProminent)
                .tint(KeyringColour.signal)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

private struct InUseMenuRow: View {
    let request: AccessRequest
    let end: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(request.login.site).font(.body)
                Text("\(request.agent.name) · \(AccessRequestCopy.origin(request.agent))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if case let .approved(_, until) = request.state {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(AccessRequestCopy.minutesLeft(until: until, now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(KeyringColour.approveText)
                }
            }
            Button("End", action: end)
                .buttonStyle(.borderless)
                .foregroundStyle(KeyringColour.denyText)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

private struct RecentMenuRow: View {
    let request: AccessRequest
    let allowAskingAgain: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(AccessRequestCopy.clock(request.askedAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(request.login.site)
                .font(.callout)
                .lineLimit(1)
            Text(request.agent.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(AccessRequestCopy.outcomeWord(request.state))
                .font(.caption.weight(.medium))
                .foregroundStyle(outcomeColour(request.state) ?? .secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .contentShape(.rect)
        .contextMenu {
            if request.state.isHoldingOffNewRequests(now: .now) {
                Button(AccessRequestCopy.letAskAgain, action: allowAskingAgain)
            }
        }
    }
}
#endif
