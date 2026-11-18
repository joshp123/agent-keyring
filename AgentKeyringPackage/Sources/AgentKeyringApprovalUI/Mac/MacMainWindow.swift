// Written by AI on 2026.11.18 by model claude opus 5.5, from the Paper
// boards "Logins and rules" and "Devices" (page "First run and the app").
//
// The window after first run: Logins, where each login has one rule and rule
// changes are saved together with one Touch ID; and Devices, the devices he
// approves on and the machines whose agents can ask.

#if os(macOS)
import LocalAuthentication
import Observation
import SwiftUI

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
    /// An always-on machine is set up.
    public var joined: Bool

    public init(logins: [LoginRow], importedAt: Date?, devices: [DeviceRow], machines: [MachineRow], joined: Bool) {
        self.logins = logins
        self.importedAt = importedAt
        self.devices = devices
        self.machines = machines
        self.joined = joined
    }
}

/// Each action that changes what agents may do is approved in macOS's own
/// dialog; the backend asks for it with the context it is given.
@MainActor
public protocol MainWindowBackend: AnyObject {
    func updates() -> AsyncStream<MainSnapshot>
    func saveRules(_ changes: [UUID: LoginRule], context: LAContext) async throws
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

    /// Changes from Ask on iPhone or Watch can be approved only there.
    public var needsPhone: Bool {
        snapshot.logins.contains { pending[$0.id] != nil && $0.rule == .askOnPhone }
    }

    public var pendingSentence: String {
        let changed = snapshot.logins.filter { pending[$0.id] != nil }
        guard changed.count == 1, let row = changed.first, let next = pending[row.id] else {
            return "The rules for \(changed.count) logins change."
        }
        return "\(row.site) changes from \(row.rule.name) to \(next.name)."
            + (row.rule == .automatic ? " An agent that has already received its password still knows it." : "")
    }

    public func cancelChanges() {
        context?.invalidate()
        pending = [:]
        failure = nil
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
                failure = ownerAuthenticationFailure(error, fallback: "That didn't finish. Nothing changed.")
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
            item("Logins", .logins)
            item("Devices", .devices)
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
            TextField("Search", text: $text).textFieldStyle(.plain).font(.system(size: 13))
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
                chip("All", nil)
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
                Pill(title: "Import Again", style: .quiet, action: model.importAgain)
            } else {
                Text(model.pendingSentence + (model.needsPhone ? " Change it on your iPhone or Watch." : ""))
                    .font(.system(size: 14)).foregroundStyle(RequestToken.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Pill(title: "Cancel", style: .quiet, action: model.cancelChanges)
                if !model.needsPhone {
                    Pill(title: model.isWorking ? "Touch the sensor to save" : "Save with Touch ID", style: .approve, action: model.save)
                        .disabled(model.isWorking)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var imported: String {
        guard let at = model.snapshot.importedAt else { return "No logins imported yet." }
        return "Imported from Apple Passwords on \(at.formatted(.dateTime.day().month(.wide))). To add newer logins, import again."
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
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("You approve on")
            ForEach(model.snapshot.devices) { device in
                DeviceLine(symbol: symbol(device.kind), name: device.isThisMac ? "This \(device.name)" : device.name,
                    detail: detail(device)) {
                    if !device.isThisMac { Pill(title: "Remove", style: .quiet) { model.remove(device.id) }.disabled(model.isWorking) }
                }
            }
            HStack {
                heading("Agents ask from")
                Spacer()
                Text("Can use Automatic logins").font(.system(size: 12)).foregroundStyle(RequestToken.ink2)
                    .padding(.trailing, model.snapshot.machines.contains { !$0.isThisMac } ? 120 : 120)
                    .padding(.top, 16)
            }
            ForEach(model.snapshot.machines) { machine in
                DeviceLine(symbol: machine.isThisMac ? "laptopcomputer" : "macmini", name: machine.isThisMac ? "This \(machine.name)" : machine.name,
                    detail: machineDetail(machine)) {
                    Toggle("", isOn: Binding(get: { machine.automatic }, set: { model.setAutomatic(machine, on: $0) }))
                        .toggleStyle(.switch).labelsHidden().tint(RequestToken.approve)
                        .disabled(machine.isThisMac || model.isWorking)
                    if machine.isThisMac { Color.clear.frame(width: 76, height: 1) } else {
                        Pill(title: "Remove", style: .quiet) { model.remove(machine.id) }.disabled(model.isWorking)
                    }
                }
            }
            Text("When Can use Automatic logins is on, agents on that machine get logins set to Automatic without asking. It starts on for your always-on machine and off for every other machine. You approve each change with Touch ID. Switching it off stops the machine getting those logins at once, but a password an agent there has already received stays known to it.")
                .font(.system(size: 12)).foregroundStyle(RequestToken.ink2).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20).padding(.vertical, 10)
            if model.snapshot.joined {
                Text("To add an iPhone, install Agent Keyring on it and open it. To add a machine, tell an agent to set up Agent Keyring on it.")
                    .font(.system(size: 13)).foregroundStyle(RequestToken.ink2)
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { RequestToken.line.frame(height: 1) }
            } else {
                Text(FirstRunCopy.awayHeading).font(.system(size: 12, weight: .semibold)).foregroundStyle(RequestToken.ink2)
                    .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)
                away
            }
        }
        .padding(.bottom, 6)
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(RequestToken.ink)
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
    }

    @ViewBuilder private var away: some View {
        VStack(alignment: .leading, spacing: 0) {
            AwayRow(title: FirstRunCopy.alwaysOn, detail: FirstRunCopy.alwaysOnBody) {
                HStack(spacing: 8) {
                    Text("“\(FirstRunCopy.alwaysOnTask)”").font(.system(size: 14)).foregroundStyle(RequestToken.ink)
                        .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .background(RequestToken.fill, in: .rect(cornerRadius: 10))
                    Pill(title: didCopy ? FirstRunCopy.copied : FirstRunCopy.copy, style: .dark) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(FirstRunCopy.alwaysOnTask, forType: .string)
                        didCopy = true
                    }
                }
                .padding(.top, 10)
            }
            AwayRow(title: FirstRunCopy.phoneAndWatch, detail: FirstRunCopy.phoneAndWatchBody) { EmptyView() }
        }
        .padding(.horizontal, 20)
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
        case .mac: "Touch ID, with the lid open."
        case .iPhone: "Face ID."
        case .watch: "One tap, unlocked on your wrist."
        }
        return how + (device.lastTested.map { " Last tested at \($0.formatted(date: .omitted, time: .shortened))." } ?? "")
    }

    private func machineDetail(_ machine: MachineRow) -> String? {
        var parts: [String] = []
        if machine.isAlwaysOn { parts.append("Your always-on machine.") }
        if let tested = machine.lastTested { parts.append("Last tested at \(tested.formatted(date: .omitted, time: .shortened)).") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
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

private struct AwayRow<Extra: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle().strokeBorder(Color(light: 0xC9C9D0, dark: 0x5A5A60), lineWidth: 2).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(RequestToken.ink2)
                Text(detail).font(.system(size: 14)).foregroundStyle(RequestToken.ink2).fixedSize(horizontal: false, vertical: true)
                extra
            }
        }
        .padding(.vertical, 14)
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
