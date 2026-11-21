// Written by AI on 2026.11.18 by model claude opus 5.5, from the Paper
// boards "Passwords and rules" and "Devices"; rebuilt on 2026.11.20 from the
// board "Mac", "Every day" (page "First run and the app").
//
// The window after first run: Passwords, where each password has one rule and
// rule changes are saved together with one Touch ID; and Devices, the devices
// he approves on and the computers whose agents can ask.

#if os(macOS)
import AppKit
import LocalAuthentication
import Observation
import SwiftUI

public struct LoginRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var site: String
    public var account: String
    public var rule: LoginRule
    /// How often agents asked for it, and how he answered; for showing and sorting.
    public var asked: Int
    public var approved: Int
    public var denied: Int
    public var lastAsked: Date?

    public init(id: UUID, site: String, account: String, rule: LoginRule, asked: Int = 0, approved: Int = 0, denied: Int = 0, lastAsked: Date? = nil) {
        self.id = id
        self.site = site
        self.account = account
        self.rule = rule
        self.asked = asked
        self.approved = approved
        self.denied = denied
        self.lastAsked = lastAsked
    }
}

/// One device in Devices, with its last practice result.
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

/// A device he answers on, with its last practice result in `detail`.
public struct DeviceRow: Identifiable, Hashable, Sendable {
    public let id: String
    public var practice: PracticeRow
    public var isThisMac: Bool

    public init(practice: PracticeRow, isThisMac: Bool) {
        self.id = practice.id
        self.practice = practice
        self.isThisMac = isThisMac
    }
}

/// What Devices' three buttons open: the same windows as first run, in a sheet.
public enum DevicesSheet: String, Identifiable, Sendable {
    case addPhoneOrWatch, addComputer, tellAgents
    public var id: String { rawValue }
}

public struct MachineRow: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var isThisMac: Bool

    public init(id: String, name: String, isThisMac: Bool) {
        self.id = id
        self.name = name
        self.isThisMac = isThisMac
    }
}

public struct MainSnapshot: Hashable, Sendable {
    public var logins: [LoginRow]
    public var importedAt: Date?
    /// The only password is first run's sample.
    public var sampleOnly: Bool
    public var devices: [DeviceRow]
    public var machines: [MachineRow]

    public init(logins: [LoginRow], importedAt: Date?, sampleOnly: Bool = false, devices: [DeviceRow], machines: [MachineRow]) {
        self.logins = logins
        self.importedAt = importedAt
        self.sampleOnly = sampleOnly
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
    func remove(id: String, context: LAContext) async throws
    func importAgain()
    /// Send Practice Request, by device key.
    func sendPractice(deviceID: String)
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

    /// Names every computer that will get a password made Automatic: saving
    /// switches on any of them not yet allowed Automatic passwords.
    public var pendingSentence: String {
        let changed = snapshot.logins.filter { pending[$0.id] != nil }
        let toAutomatic = changed.filter { pending[$0.id] == .automatic }.count
        let computers = snapshot.machines.map { $0.isThisMac ? "this Mac" : $0.name }
        let automatic = toAutomatic > 0 ? MainWindowCopy.automaticTo(computers, count: toAutomatic) : ""
        guard changed.count == 1, let row = changed.first, let next = pending[row.id] else {
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

    public func save() { run { [pending, backend] context in try await backend.saveRules(pending, context: context) } done: { self.pending = [:] } }

    public func sendPractice(_ id: String) { backend.sendPractice(deviceID: id) }

    /// Sort with AI: a prompt with each password's website, account and rule, never a password.
    public func copySortPrompt() {
        let rows = snapshot.logins.map { (site: $0.site, account: $0.account, rule: rule(of: $0).name) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MainWindowCopy.sortPrompt(rows), forType: .string)
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
    /// The windows Devices' buttons open, drawn by the app.
    let sheetContent: (DevicesSheet, @escaping () -> Void) -> AnyView
    @State private var sheet: DevicesSheet?

    public init(model: MacMainModel, sheet: @escaping (DevicesSheet, @escaping () -> Void) -> AnyView = { _, _ in AnyView(EmptyView()) }) {
        self.model = model
        self.sheetContent = sheet
    }

    public var body: some View {
        VStack(spacing: 0) {
            switch model.tab {
            case .logins: LoginsTab(model: model)
            case .devices: DevicesTab(model: model, open: { sheet = $0 })
            }
        }
        .frame(width: 820)
        .fixedSize(horizontal: false, vertical: true)
        .background(RequestToken.surface)
        // One toolbar row: the window's buttons, Passwords | Devices in the centre, Search on Passwords.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(MainWindowCopy.passwordsTab, selection: $model.tab) {
                    Text(MainWindowCopy.passwordsTab).tag(MacMainModel.Tab.logins)
                    Text(MainWindowCopy.devicesTab).tag(MacMainModel.Tab.devices)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if model.tab == .logins {
                ToolbarItem(placement: .primaryAction) { SearchField(text: $model.search).frame(width: 200) }
            }
        }
        .toolbar(removing: .title)
        .sheet(item: $sheet) { which in sheetContent(which) { sheet = nil } }
        .task { await model.followUpdates() }
        .alert(SetupCopy.appName, isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.dismissFailure() } })) {
            Button(SetupCopy.ok) { model.dismissFailure() }
        } message: { Text(model.failure ?? "") }
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

    @State private var promptCopied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    rule(LoginRule.ask.name, MainWindowCopy.askExplained)
                    rule(LoginRule.automatic.name, MainWindowCopy.automaticExplained)
                    rule(LoginRule.blocked.name, MainWindowCopy.blockedExplained)
                }
                .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RequestToken.fill, in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 10) {
                    Text(MainWindowCopy.sortBody(model.snapshot.logins.count)).font(.system(size: 13)).lineSpacing(2)
                        .foregroundStyle(RequestToken.ink).fixedSize(horizontal: false, vertical: true)
                    Pill(title: promptCopied ? MainWindowCopy.sortCopied : MainWindowCopy.sortWithAI, style: .dark) {
                        model.copySortPrompt()
                        promptCopied = true
                    }
                }
                .padding(14).frame(width: 300, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top)
                .background(RequestToken.fill, in: .rect(cornerRadius: 14))
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20).padding(.top, 14)
            HStack {
                Picker(MainWindowCopy.all, selection: $model.filter) {
                    Text(label(MainWindowCopy.all, nil)).tag(LoginRule?.none)
                    ForEach(LoginRule.allCases, id: \.self) { Text(label($0.name, $0)).tag(LoginRule?.some($0)) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
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

    /// "Ask: an agent asks you each time it needs the password."
    private func rule(_ name: String, _ meaning: String) -> some View {
        (Text(name + ": ").fontWeight(.semibold) + Text(meaning)).font(.system(size: 13)).lineSpacing(2)
            .foregroundStyle(RequestToken.ink).fixedSize(horizontal: false, vertical: true)
    }

    /// "Ask 528": the rule and how many passwords have it, the count in grey.
    private func label(_ title: String, _ rule: LoginRule?) -> AttributedString {
        var name = AttributedString(title + " ")
        name.foregroundColor = .primary
        var count = AttributedString("\(model.count(rule))")
        count.foregroundColor = .secondary
        return name + count
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            if model.pending.isEmpty {
                Text(imported).font(.system(size: 13)).foregroundStyle(RequestToken.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Pill(title: model.snapshot.sampleOnly ? MainWindowCopy.copyFromPasswords : MainWindowCopy.copyAgain,
                    style: .quiet, action: model.importAgain)
            } else {
                Text(model.pendingSentence)
                    .font(.system(size: 14)).foregroundStyle(RequestToken.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Pill(title: MainWindowCopy.cancel, style: .quiet, action: model.cancelChanges)
                Pill(title: model.isWorking ? MainWindowCopy.useTouchIDToSave : MainWindowCopy.saveWithTouchID, style: .approve, action: model.save)
                    .disabled(model.isWorking)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var imported: String {
        if model.snapshot.sampleOnly { return MainWindowCopy.sampleOnly }
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
    let open: (DevicesSheet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(MainWindowCopy.devicesIntro).font(.system(size: 13)).foregroundStyle(RequestToken.ink2)
                .padding(.horizontal, 20).padding(.top, 16)
            heading(MainWindowCopy.whereYouAnswer)
            ForEach(model.snapshot.devices) { device in
                let row = device.practice
                DeviceLine(symbol: row.symbol, name: row.name, detail: row.detail, tone: row.tone) {
                    Pill(title: FirstRunCopy.sendPractice, style: .quiet) { model.sendPractice(row.id) }.disabled(!row.canSend)
                    if !device.isThisMac { Pill(title: MainWindowCopy.remove, style: .remove) { model.remove(device.id) }.disabled(model.isWorking) }
                }
            }
            rule
            heading(MainWindowCopy.computersThatAsk)
            ForEach(model.snapshot.machines) { machine in
                DeviceLine(symbol: machine.isThisMac ? "laptopcomputer" : "macmini", name: machine.name, detail: machineDetail(machine)) {
                    if !machine.isThisMac { Pill(title: MainWindowCopy.remove, style: .remove) { model.remove(machine.id) }.disabled(model.isWorking) }
                }
            }
            rule
            HStack(spacing: 8) {
                Pill(title: MainWindowCopy.addPhoneOrWatch, style: .quiet) { open(.addPhoneOrWatch) }
                Pill(title: MainWindowCopy.addComputer, style: .quiet) { open(.addComputer) }
                Pill(title: MainWindowCopy.tellYourAgents, style: .quiet) { open(.tellAgents) }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
    }

    /// The line under the last row of a list.
    private var rule: some View { RequestToken.line.frame(height: 1).padding(.horizontal, 20) }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(RequestToken.ink)
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 10)
    }

    private func machineDetail(_ machine: MachineRow) -> String? {
        machine.isThisMac ? MainWindowCopy.thisMac : nil
    }
}

private struct DeviceLine<Trailing: View>: View {
    let symbol: String
    let name: String
    let detail: String?
    var tone = PracticeRow.Tone.plain
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(RequestToken.ink).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(RequestToken.ink)
                if let detail {
                    Text(detail).font(.system(size: 13))
                        .foregroundStyle(tone == .approved ? RequestToken.approve : tone == .denied ? RequestToken.deny : RequestToken.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { RequestToken.line.frame(height: 1) }
        .padding(.horizontal, 20)
    }
}

private struct Pill: View {
    enum Style { case quiet, approve, dark, remove }
    let title: String
    let style: Style
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, style == .approve ? 16 : 12).frame(height: style == .approve ? 32 : 28)
                .background(background, in: Capsule())
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain).fixedSize()
    }

    private var foreground: Color {
        switch style {
        case .quiet: RequestToken.ink
        case .dark: RequestToken.surface
        case .approve: RequestToken.onAnswer
        case .remove: RequestToken.deny
        }
    }

    private var background: Color {
        switch style {
        case .quiet, .remove: RequestToken.fill
        case .dark: RequestToken.ink
        case .approve: RequestToken.approve
        }
    }
}
#endif
