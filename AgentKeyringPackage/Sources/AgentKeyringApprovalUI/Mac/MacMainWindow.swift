// Written by AI on 2026.11.18 by model claude opus 5.5; rebuilt on 2026.11.21
// by the same model from the shared page parts, the copy ledger of 21
// November and the Paper page "Agent Keyring (Holistic)", board 3.
//
// The window after first run: Passwords, where each password has one rule and
// rule changes are saved together with one Touch ID; and Devices, where he
// approves and which computers' agents can ask. The tabs are in
// MacPasswordsTab.swift and MacDevicesTab.swift.

#if os(macOS)
import AppKit
import AgentKeyringApprovalCore
import AgentKeyringDesign
import LocalAuthentication
import Observation
import SwiftUI

public struct LoginRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var site: String
    public var account: String
    public var rule: LoginRule
    /// How often agents asked for it, and how he answered.
    public var asked: Int
    public var approved: Int
    public var denied: Int
    /// The example.com password Agent Keyring always keeps.
    public var isTestPassword: Bool

    public init(id: UUID, site: String, account: String, rule: LoginRule, asked: Int = 0, approved: Int = 0, denied: Int = 0,
        isTestPassword: Bool = false) {
        self.id = id
        self.site = site
        self.account = account
        self.rule = rule
        self.asked = asked
        self.approved = approved
        self.denied = denied
        self.isTestPassword = isTestPassword
    }

    /// For sorting by rule: Ask, Automatic, Blocked.
    public var ruleOrder: Int { LoginRule.allCases.firstIndex(of: rule) ?? 0 }
}

/// Where a practice request on one device is up to.
public enum PracticeStatus: Hashable, Sendable {
    /// On this Mac: the practice card is beside the window.
    case waitingHere
    case sending
    case withApple
    /// The iPhone or Apple Watch said it arrived.
    case arrived
    case approved
    case denied
    case noAnswer
    /// The sentence the Mac gave for why it could not be sent.
    case failed(String)

    public var isUnderWay: Bool { [.waitingHere, .sending, .withApple, .arrived].contains(self) }
}

/// A device he approves on: this Mac, an iPhone or an Apple Watch.
public struct ApproverRow: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case thisMac, iPhone, watch }
    public let id: String
    public var kind: Kind
    public var name: String
    public var practice: PracticeStatus?
    /// The Mac can send this device a practice request now.
    public var canPractise: Bool

    public init(id: String, kind: Kind, name: String, practice: PracticeStatus? = nil, canPractise: Bool) {
        self.id = id
        self.kind = kind
        self.name = name
        self.practice = practice
        self.canPractise = canPractise
    }
}

/// Another computer whose agents can ask.
public struct ComputerRow: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// What stops this Mac reaching his other devices, said plainly on Devices.
public enum DoorNotice: Hashable, Sendable {
    /// No Tailscale address on this Mac.
    case noTailscale
    /// No push key from `agent-keyring push-key`.
    case noPushKey
    /// A port could not be opened; the Mac tries again by itself.
    case failed
}

/// What the Add Device menu opens: the same sheets as first run.
public enum DevicesSheet: String, Identifiable, Sendable {
    case addIPhone, addComputer
    public var id: String { rawValue }
}

public struct MainSnapshot: Hashable, Sendable {
    public var logins: [LoginRow]
    public var importedAt: Date?
    /// The only password is the test password.
    public var sampleOnly: Bool
    public var approvers: [ApproverRow]
    /// Other computers, not this Mac.
    public var computers: [ComputerRow]
    public var notices: [DoorNotice]
    /// Password changes the other devices have not been sent, after Not Now.
    public var unsentChanges: Int

    public init(logins: [LoginRow], importedAt: Date?, sampleOnly: Bool = false, approvers: [ApproverRow] = [],
        computers: [ComputerRow] = [], notices: [DoorNotice] = [], unsentChanges: Int = 0) {
        self.logins = logins
        self.importedAt = importedAt
        self.sampleOnly = sampleOnly
        self.approvers = approvers
        self.computers = computers
        self.notices = notices
        self.unsentChanges = unsentChanges
    }
}

/// Each action that changes what agents may do is approved in macOS's own
/// dialog; the backend asks for it with the context it is given.
@MainActor
public protocol MainWindowBackend: AnyObject {
    func updates() -> AsyncStream<MainSnapshot>
    func saveRules(_ changes: [UUID: LoginRule], context: LAContext) async throws
    func remove(id: String, context: LAContext) async throws
    func rename(id: String, to newName: String, context: LAContext) async throws
    func importAgain()
    /// Send Practice Request, by device key.
    func sendPractice(deviceID: String)
    /// Send Updates: asks again, beside the window, to send the unsent changes.
    func sendUpdates()
}

@MainActor
@Observable
public final class MacMainModel {
    public enum Tab: Hashable, Sendable { case logins, devices }

    public var tab = Tab.logins
    public private(set) var snapshot: MainSnapshot
    public var filter: LoginRule?
    public var search = ""
    /// Most asked first, as the board draws it.
    public var sortOrder = [KeyPathComparator(\LoginRow.asked, order: .reverse)]
    /// Rule changes not yet saved, by login.
    public private(set) var pending: [UUID: LoginRule] = [:]
    /// Single explicit dialog state on Devices so Rename and Remove can never stack or overlap.
    public enum DeviceDialog: Equatable, Sendable {
        case rename(id: String, name: String)
        case remove(id: String, name: String, isComputer: Bool)
    }

    public private(set) var isWorking = false
    public private(set) var failure: String?
    public var deviceDialog: DeviceDialog?
    public var renameDraft = ""
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
        .sorted(using: sortOrder)
    }

    public func choose(_ rule: LoginRule, for row: LoginRow) {
        failure = nil
        pending[row.id] = rule == row.rule ? nil : rule
    }

    /// Names every computer that will get a password made Automatic.
    public var pendingSentence: String {
        let changed = snapshot.logins.filter { pending[$0.id] != nil }
        let toAutomatic = changed.filter { pending[$0.id] == .automatic }.count
        let computers = [MainWindowCopy.thisMacInSentence] + snapshot.computers.map(\.name)
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

    public func sendUpdates() { backend.sendUpdates() }

    // MARK: Sort with AI

    /// The prompt for an agent: each password's website, account and rule, never a password.
    public var sortPrompt: String {
        MainWindowCopy.sortPrompt(snapshot.logins.map { (site: $0.site, account: $0.account, rule: rule(of: $0).name) })
    }

    /// Reads an agent's reply, one line per password (website, account, rule,
    /// separated by tabs or a table's bars), and makes each suggestion a
    /// pending change for him to review and save. Returns how many changed.
    @discardableResult
    public func applySuggestions(_ reply: String) -> Int {
        var applied = 0
        for line in reply.split(whereSeparator: \.isNewline) {
            let cells = line.split(whereSeparator: { $0 == "\t" || $0 == "|" })
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`*")) }
                .filter { !$0.isEmpty }
            guard cells.count >= 3,
                let suggested = LoginRule.allCases.first(where: { $0.name.caseInsensitiveCompare(cells[cells.count - 1]) == .orderedSame }),
                let row = snapshot.logins.first(where: {
                    $0.site.caseInsensitiveCompare(cells[0]) == .orderedSame && $0.account.caseInsensitiveCompare(cells[1]) == .orderedSame
                }), rule(of: row) != suggested
            else { continue }
            choose(suggested, for: row)
            applied += 1
        }
        return applied
    }

    // MARK: Devices

    public func askToRemove(_ id: String, name: String, isComputer: Bool) {
        guard !isWorking else { return }
        deviceDialog = .remove(id: id, name: name, isComputer: isComputer)
    }

    public func remove(_ id: String) {
        deviceDialog = nil
        run { [backend] context in try await backend.remove(id: id, context: context) }
    }

    public func askToRename(_ id: String, name: String) {
        guard !isWorking else { return }
        renameDraft = name
        deviceDialog = .rename(id: id, name: name)
    }

    public func commitRename() {
        guard case let .rename(id, oldName) = deviceDialog else { return }
        let next = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        deviceDialog = nil
        guard !next.isEmpty, next != oldName else { return }
        run { [backend] context in try await backend.rename(id: id, to: next, context: context) }
    }

    public func dismissDeviceDialog() { deviceDialog = nil }

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

/// The window: Passwords | Devices in the toolbar's centre, Search on
/// Passwords, Add Device on Devices. Its size is the app's to set.
public struct MacMainWindowView: View {
    private enum WindowSheet: String, Identifiable {
        case addIPhone, addComputer, sortWithAI
        var id: String { rawValue }
    }

    @Bindable var model: MacMainModel
    /// The sheets Add Device opens, drawn by the app.
    let sheetContent: (DevicesSheet, @escaping () -> Void) -> AnyView
    @State private var sheet: WindowSheet?

    public init(model: MacMainModel, sheet: @escaping (DevicesSheet, @escaping () -> Void) -> AnyView) {
        self.model = model
        self.sheetContent = sheet
    }

    public var body: some View {
        Group {
            switch model.tab {
            case .logins: MacPasswordsTab(model: model, openSortWithAI: { sheet = .sortWithAI })
            case .devices: MacDevicesTab(model: model)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(MainWindowCopy.passwordsTab, selection: $model.tab) {
                    Text(MainWindowCopy.passwordsTab).tag(MacMainModel.Tab.logins)
                    Text(MainWindowCopy.devicesTab).tag(MacMainModel.Tab.devices)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if model.tab == .devices {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(MainWindowCopy.addIPhone) { sheet = .addIPhone }
                        Button(MainWindowCopy.addComputer) { sheet = .addComputer }
                    } label: {
                        Label(MainWindowCopy.addDevice, systemImage: "plus")
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
        }
        .toolbar(removing: .title)
        .onChange(of: model.tab) { _, _ in model.dismissDeviceDialog() }
        .sheet(item: $sheet) { which in
            switch which {
            case .addIPhone: sheetContent(.addIPhone) { sheet = nil }
            case .addComputer: sheetContent(.addComputer) { sheet = nil }
            case .sortWithAI:
                SortWithAISheet(model: model) { sheet = nil }
                    .frame(width: KeyringSize.measure + 2 * KeyringSpace.s10)
            }
        }
        .task { await model.followUpdates() }
        .alert(MenuBarCopy.appName, isPresented: Binding(get: { model.failure != nil && model.deviceDialog == nil }, set: { if !$0 { model.dismissFailure() } })) {
            Button(SetupCopy.ok) { model.dismissFailure() }
        } message: { Text(model.failure ?? "") }
    }
}
#endif
