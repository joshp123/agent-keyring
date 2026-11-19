// Written by AI on 2026.11.18 by model claude opus 5.5, from the Paper
// boards "Passwords and rules" and "Devices" (page "First run and the app").
//
// The window after first run: Passwords, where each password has one rule and
// rule changes are saved together with one Touch ID; and Devices, the devices
// he approves on and the computers whose agents can ask.

#if os(macOS)
import LocalAuthentication
import Observation
import SwiftUI

public enum ProposalOutcome: Sendable { case approved, denied, unanswered }

public struct LoginRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var site: String
    public var account: String
    public var rule: LoginRule

    public init(id: UUID, site: String, account: String, rule: LoginRule) {
        self.id = id
        self.site = site
        self.account = account
        self.rule = rule
    }
}

public struct DeviceRow: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case mac, iPhone, watch }
    public let id: String
    public var name: String
    public var kind: Kind
    public var lastTested: Date?
    public var isThisMac: Bool

    public init(id: String, name: String, kind: Kind, lastTested: Date?, isThisMac: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.lastTested = lastTested
        self.isThisMac = isThisMac
    }
}

public struct MachineRow: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var isThisMac: Bool
    public var isAlwaysOn: Bool
    public var automatic: Bool
    public var lastTested: Date?

    public init(id: String, name: String, isThisMac: Bool, isAlwaysOn: Bool, automatic: Bool, lastTested: Date?) {
        self.id = id
        self.name = name
        self.isThisMac = isThisMac
        self.isAlwaysOn = isAlwaysOn
        self.automatic = automatic
        self.lastTested = lastTested
    }
}

public struct MainSnapshot: Hashable, Sendable {
    public var logins: [LoginRow]
    public var importedAt: Date?
    public var devices: [DeviceRow]
    public var machines: [MachineRow]

    public init(logins: [LoginRow], importedAt: Date?, devices: [DeviceRow], machines: [MachineRow]) {
        self.logins = logins
        self.importedAt = importedAt
        self.devices = devices
        self.machines = machines
    }
}

/// Each action that changes what agents may do is approved in macOS's own
/// dialog; the backend asks for it with the context it is given.
@MainActor
public protocol MainWindowBackend: AnyObject {
    func updates() -> AsyncStream<MainSnapshot>
    func saveRules(_ changes: [UUID: LoginRule], context: LAContext) async throws
    /// Changes away from Ask on iPhone or Apple Watch: sent to the iPhone, and how it answered.
    func proposeRules(_ changes: [UUID: LoginRule]) async throws -> ProposalOutcome
    func setAutomatic(machineID: String, on: Bool, context: LAContext) async throws
    func remove(id: String, context: LAContext) async throws
    func importAgain()
}

@MainActor
@Observable
public final class MacMainModel {
    public enum Tab: Hashable, Sendable { case logins, devices }

    public var tab = Tab.logins
    public private(set) var snapshot: MainSnapshot
    public var filter: LoginRule?
    public var search = ""
    /// Rule changes not yet saved, by login.
    public private(set) var pending: [UUID: LoginRule] = [:]
    public private(set) var isWorking = false
    public private(set) var failure: String?
    private let backend: any MainWindowBackend
    private var context: LAContext?

    public init(backend: any MainWindowBackend, initial: MainSnapshot) {
        self.backend = backend
        self.snapshot = initial
    }

    public func followUpdates() async {
        for await next in backend.updates() { snapshot = next }
    }

    public func rule(of row: LoginRow) -> LoginRule { pending[row.id] ?? row.rule }

    public func count(_ rule: LoginRule?) -> Int {
        guard let rule else { return snapshot.logins.count }
        return snapshot.logins.lazy.filter { self.rule(of: $0) == rule }.count
    }

    public var visibleLogins: [LoginRow] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return snapshot.logins.filter { row in
            (filter == nil || rule(of: row) == filter)
                && (query.isEmpty || row.site.lowercased().contains(query) || row.account.lowercased().contains(query))
        }
    }

    public func choose(_ rule: LoginRule, for row: LoginRow) {
        failure = nil
        pending[row.id] = rule == row.rule ? nil : rule
    }

    /// Only changes away from Ask on iPhone or Apple Watch go to the iPhone;
    /// this Mac makes every other change itself, with Touch ID.
    private var phoneChanges: [UUID: LoginRule] {
        pending.filter { id, _ in snapshot.logins.first { $0.id == id }?.rule == .askOnPhone }
    }

    public var needsPhone: Bool { !phoneChanges.isEmpty }

    /// Names every computer that will get a password made Automatic: saving
    /// switches on any of them not yet allowed Automatic passwords.
    public var pendingSentence: String {
        let shown = needsPhone ? phoneChanges : pending
        let changed = snapshot.logins.filter { shown[$0.id] != nil }
        let toAutomatic = changed.filter { shown[$0.id] == .automatic }.count
        let computers = snapshot.machines.map { $0.isThisMac ? "this Mac" : $0.name }
        let automatic = toAutomatic > 0 && !needsPhone ? MainWindowCopy.automaticTo(computers, count: toAutomatic) : ""
        guard changed.count == 1, let row = changed.first, let next = shown[row.id] else {
            return MainWindowCopy.rulesChange(changed.count) + automatic
        }
        return MainWindowCopy.ruleChange(site: row.site, from: row.rule.name, to: next.name)
            + (row.rule == .automatic ? MainWindowCopy.stillKnown : "") + automatic
    }

    public func cancelChanges() {
        context?.invalidate()
        pending = [:]
        failure = nil
    }

    /// Sends the changes away from Ask on iPhone or Apple Watch to the iPhone and
    /// waits; any other changes stay, to be saved here with Touch ID.
    public func sendToPhone() {
        guard !isWorking else { return }
        let changes = phoneChanges
        let still = MainWindowCopy.stillOnPhone(snapshot.logins.filter { changes[$0.id] != nil }.map(\.site))
        isWorking = true
        failure = nil
        Task {
            defer { isWorking = false }
            do {
                switch try await backend.proposeRules(changes) {
                case .approved: for id in changes.keys { pending[id] = nil }
                case .denied: failure = MainWindowCopy.deniedOnPhone + still
                case .unanswered: failure = MainWindowCopy.noAnswerOnPhone + still
                }
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? MainWindowCopy.notSentToPhone
            }
        }
    }

    public func save() { run { [pending, backend] context in try await backend.saveRules(pending, context: context) } done: { self.pending = [:] } }

    public func setAutomatic(_ machine: MachineRow, on: Bool) {
        run { [backend] context in try await backend.setAutomatic(machineID: machine.id, on: on, context: context) }
    }

    public func remove(_ id: String) {
        run { [backend] context in try await backend.remove(id: id, context: context) }
    }

    public func importAgain() { backend.importAgain() }

    public func dismissFailure() { failure = nil }

    private func run(_ action: @escaping @MainActor (LAContext) async throws -> Void, done: @escaping @MainActor () -> Void = {}) {
        guard !isWorking else { return }
        let context = LAContext()
        self.context = context
        isWorking = true
        failure = nil
        Task {
            defer { isWorking = false; self.context = nil }
            do {
                try await action(context)
                done()
            } catch is CancellationError {
            } catch {
                failure = ownerAuthenticationFailure(error, fallback: MainWindowCopy.didNotFinish)
            }
        }
    }
}

public struct MacMainWindowView: View {
    @Bindable var model: MacMainModel

    public init(model: MacMainModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Color.clear.frame(width: 200, height: 1)
                Spacer(minLength: 0)
                Segmented(selection: $model.tab)
                Spacer(minLength: 0)
                if model.tab == .logins {
                    SearchField(text: $model.search).frame(width: 200)
                } else {
                    Color.clear.frame(width: 200, height: 1)
                }
            }
            .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 14)
            switch model.tab {
            case .logins: LoginsTab(model: model)
            case .devices: DevicesTab(model: model)
            }
        }
        .frame(width: 820)
        .fixedSize(horizontal: false, vertical: true)
        .background(RequestToken.surface)
        .task { await model.followUpdates() }
        .alert("Agent Keyring", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.dismissFailure() } })) {
            Button("OK") { model.dismissFailure() }
        } message: { Text(model.failure ?? "") }
    }
}

private struct Segmented: View {
    @Binding var selection: MacMainModel.Tab

    var body: some View {
        HStack(spacing: 2) {
            item(MainWindowCopy.passwordsTab, .logins)
            item(MainWindowCopy.devicesTab, .devices)
        }
        .padding(3)
        .background(RequestToken.fill, in: Capsule())
    }

    private func item(_ title: String, _ tab: MacMainModel.Tab) -> some View {
        Button { selection = tab } label: {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selection == tab ? RequestToken.ink : RequestToken.ink2)
                .padding(.horizontal, 16).frame(height: 26)
                .background {
                    if selection == tab {
                        Capsule().fill(RequestToken.surface).shadow(color: .black.opacity(0.16), radius: 1.5, y: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(RequestToken.ink2)
            TextField(MainWindowCopy.search, text: $text).textFieldStyle(.plain).font(.system(size: 13))
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(RequestToken.fill, in: Capsule())
    }
}

private struct LoginsTab: View {
    @Bindable var model: MacMainModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                chip(MainWindowCopy.all, nil)
                ForEach(LoginRule.allCases, id: \.self) { chip($0.name, $0) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visibleLogins) { row in
                        HStack(spacing: 10) {
                            Text(row.site).font(.system(size: 14, weight: .semibold)).foregroundStyle(RequestToken.ink)
                                .lineLimit(1).frame(width: 230, alignment: .leading)
                            Text(row.account).font(.system(size: 13)).foregroundStyle(RequestToken.ink2).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            RuleMenu(rule: model.rule(of: row)) { model.choose($0, for: row) }
                        }
                        .padding(.horizontal, 20).frame(height: 46)
                        .overlay(alignment: .top) { RequestToken.line.frame(height: 1) }
                    }
                }
            }
            .frame(height: 420)
            footer.overlay(alignment: .top) { RequestToken.line.frame(height: 1) }
        }
    }

    private func chip(_ title: String, _ rule: LoginRule?) -> some View {
        let selected = model.filter == rule
        return Button { model.filter = rule } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? RequestToken.surface : RequestToken.ink)
                Text("\(model.count(rule))").font(.system(size: 13))
                    .foregroundStyle(selected ? RequestToken.surface.opacity(0.7) : RequestToken.ink2)
            }
            .padding(.horizontal, 12).frame(height: 28)
            .background(selected ? RequestToken.ink : RequestToken.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            if model.pending.isEmpty {
                Text(imported).font(.system(size: 13)).foregroundStyle(RequestToken.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Pill(title: MainWindowCopy.copyAgain, style: .quiet, action: model.importAgain)
            } else {
                Text(model.pendingSentence)
                    .font(.system(size: 14)).foregroundStyle(RequestToken.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Pill(title: MainWindowCopy.cancel, style: .quiet, action: model.cancelChanges)
                if model.needsPhone {
                    Button(action: model.sendToPhone) {
                        Label(model.isWorking ? MainWindowCopy.waitingForPhone : MainWindowCopy.approveOnPhone, systemImage: "iphone")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(RequestToken.ink)
                    }
                    .buttonStyle(.plain).disabled(model.isWorking)
                } else {
                    Pill(title: model.isWorking ? MainWindowCopy.useTouchIDToSave : MainWindowCopy.saveWithTouchID, style: .approve, action: model.save)
                        .disabled(model.isWorking)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var imported: String {
        guard let at = model.snapshot.importedAt else { return MainWindowCopy.noneCopied }
        return MainWindowCopy.copiedOn(at.formatted(.dateTime.day().month(.wide)))
    }
}

private struct RuleMenu: View {
    let rule: LoginRule
    let choose: (LoginRule) -> Void

    var body: some View {
        Menu {
            ForEach(LoginRule.allCases, id: \.self) { option in
                Button { choose(option) } label: {
                    Text(option.name)
                    Text(option.explanation)
                    if option == rule { Image(systemName: "checkmark") }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(rule.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(RequestToken.ink)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(RequestToken.ink2)
            }
            .padding(.leading, 12).padding(.trailing, 8).frame(height: 28)
            .background(RequestToken.fill, in: Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

private struct DevicesTab: View {
    @Bindable var model: MacMainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(MainWindowCopy.youApproveOn)
            ForEach(model.snapshot.devices) { device in
                DeviceLine(symbol: symbol(device.kind), name: device.isThisMac ? MainWindowCopy.this(device.name) : device.name,
                    detail: detail(device)) {
                    if !device.isThisMac { Pill(title: MainWindowCopy.remove, style: .quiet) { model.remove(device.id) }.disabled(model.isWorking) }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                heading(MainWindowCopy.agentsAskFrom)
                Spacer()
                Text(MainWindowCopy.automaticPasswords).font(.system(size: 12)).foregroundStyle(RequestToken.ink2)
                    .fixedSize().frame(width: 120).padding(.trailing, 96)
            }
            ForEach(model.snapshot.machines) { machine in
                DeviceLine(symbol: machine.isThisMac ? "laptopcomputer" : "macmini",
                    name: machine.isThisMac ? MainWindowCopy.this(machine.name) : machine.name, detail: machineDetail(machine)) {
                    Toggle("", isOn: Binding(get: { machine.automatic }, set: { model.setAutomatic(machine, on: $0) }))
                        .toggleStyle(.switch).labelsHidden().tint(RequestToken.approve)
                        .disabled(model.isWorking)
                        .frame(width: 120)
                    if machine.isThisMac { Color.clear.frame(width: 76, height: 1) } else {
                        Pill(title: MainWindowCopy.remove, style: .quiet) { model.remove(machine.id) }.disabled(model.isWorking)
                            .frame(width: 76, alignment: .trailing)
                    }
                }
            }
            AgentLineBox(caption: MainWindowCopy.toAdd, line: FirstRunCopy.agentLine)
                .padding(14)
                .background(RequestToken.fill, in: .rect(cornerRadius: 12))
                .padding(.horizontal, 20).padding(.vertical, 12)
                .overlay(alignment: .top) { RequestToken.line.frame(height: 1) }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(RequestToken.ink)
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
    }

    private func symbol(_ kind: DeviceRow.Kind) -> String {
        switch kind {
        case .mac: "laptopcomputer"
        case .iPhone: "iphone"
        case .watch: "applewatch"
        }
    }

    private func detail(_ device: DeviceRow) -> String {
        let how = switch device.kind {
        case .mac: MainWindowCopy.macApproves
        case .iPhone: MainWindowCopy.phoneApproves
        case .watch: MainWindowCopy.watchApproves
        }
        return device.lastTested == nil ? how : how + " · " + MainWindowCopy.ready
    }

    private func machineDetail(_ machine: MachineRow) -> String? {
        machine.isAlwaysOn ? MainWindowCopy.staysOn : nil
    }
}

private struct DeviceLine<Trailing: View>: View {
    let symbol: String
    let name: String
    let detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(RequestToken.ink).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(RequestToken.ink)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(RequestToken.ink2).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .overlay(alignment: .top) { RequestToken.line.frame(height: 1) }
    }
}

private struct Pill: View {
    enum Style { case quiet, approve, dark }
    let title: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(style == .quiet ? RequestToken.ink : style == .dark ? RequestToken.surface : RequestToken.onAnswer)
                .padding(.horizontal, style == .approve ? 16 : 12).frame(height: style == .quiet ? 28 : 32)
                .background(style == .quiet ? RequestToken.fill : style == .dark ? RequestToken.ink : RequestToken.approve, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
#endif
