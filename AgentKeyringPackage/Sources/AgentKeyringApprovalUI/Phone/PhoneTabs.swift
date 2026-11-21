// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The app after first run: Home, Passwords and Devices, the same three things
// as the Mac, from the shared page parts in system lists.

#if os(iOS)
import AgentKeyringDesign
import SwiftUI

public struct PhoneRootView: View {
    @Bindable var model: PhoneModel

    public init(model: PhoneModel) { self.model = model }

    public var body: some View {
        Group {
            if model.snapshot.firstRun != .finished {
                PhoneFirstRunView(stage: model.snapshot.firstRun, model: model)
            } else {
                TabView(selection: $model.tab) {
                    Tab(value: PhoneTab.home) { PhoneHomeView(model: model) } label: {
                        Label { Text(PhoneCopy.home) } icon: { Image(uiImage: TabGlyph.outline("clock")) }
                    }
                    Tab(value: PhoneTab.logins) { PhoneLoginsView(model: model) } label: {
                        Label { Text(PhoneCopy.passwords) } icon: { Image(uiImage: KeyholeGlyph.image) }
                    }
                    Tab(value: PhoneTab.devices) { PhoneDevicesView(model: model) } label: {
                        Label { Text(PhoneCopy.devices) } icon: { Image(uiImage: TabGlyph.outline("iphone")) }
                    }
                }
            }
        }
        .task { await model.followUpdates() }
        .alert(model.failure ?? "", isPresented: failureShown) { Button(PhoneCopy.ok) { model.dismissFailure() } }
        .sheet(item: shownRequest) { request in
            // The sheet's top bar (Cancel, and how long ago it was asked) is the system's.
            NavigationStack { PhoneRequestView(model: model, request: request, practice: request.isPractice).toolbar { requestBar(request) } }
        }
        .sheet(item: practiceShown) { request in
            NavigationStack { PhoneRequestView(model: model, request: request, practice: true).toolbar { requestBar(request) } }
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: addWatchShown) {
            PhoneAddWatchView(flow: model.snapshot.addWatch, model: model).interactiveDismissDisabled()
        }
    }

    @ToolbarContentBuilder private func requestBar(_ request: AccessRequest) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { Button(PhoneCopy.cancel) { model.shownRequestID = nil } }
        ToolbarItem(placement: .topBarTrailing) { KeyringText(PhoneCopy.askedAgo(request.askedAt), as: .caption) }
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { model.failure != nil && model.shownRequestID == nil }, set: { if !$0 { model.dismissFailure() } })
    }

    /// The practice request, while first run has it open.
    private var practiceShown: Binding<AccessRequest?> {
        Binding(get: { model.snapshot.practiceRequest }, set: { _ in })
    }


    /// Adding Apple Watch from Devices, after first run.
    private var addWatchShown: Binding<Bool> {
        Binding(get: { model.snapshot.firstRun == .finished && model.snapshot.addWatch != nil }, set: { _ in })
    }

    private var shownRequest: Binding<AccessRequest?> {
        Binding(get: { model.shownRequestID.flatMap(model.request(id:)).flatMap { $0.state.isWaitingForYou ? $0 : nil } },
                set: { model.shownRequestID = $0?.id })
    }
}

/// A system grouped list under a navigation title.
private struct PhoneList<Content: View>: View {
    let title: String
    /// Home's Settings, at the top left.
    var leading: (label: String, action: () -> Void)? = nil
    /// A small pill beside the title: Home's count of requests waiting.
    var pill: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            List { content }
                .listStyle(.insetGrouped)
                .navigationTitle(title)
                .toolbar {
                    if let leading {
                        ToolbarItem(placement: .topBarLeading) { Button(leading.label, action: leading.action) }
                    }
                    if let pill {
                        ToolbarItem(placement: .topBarTrailing) { KeyringText(pill, as: .caption, colour: KeyringPalette.brand) }
                    }
                }
        }
    }
}

/// Home: what needs an answer, what is in use, earlier today, and a practice request.
struct PhoneHomeView: View {
    let model: PhoneModel

    /// -SampleSettings YES opens Settings, for looking at it in the simulator.
    @State private var settingsShown = UserDefaults.standard.bool(forKey: "SampleSettings")

    var body: some View {
        PhoneList(title: PhoneCopy.home, leading: (PhoneCopy.settings, { settingsShown = true }),
                  pill: model.waiting.isEmpty ? nil : PhoneCopy.waitingPill(model.waiting.count)) {
            if let problem = model.snapshot.notices.first(where: { $0 != .addAppleWatch }) {
                Section { KeyringStatusLine(.problem(PhoneCopy.notice(problem))) }
            }
            if model.waiting.isEmpty && model.inUse.isEmpty && earlier.isEmpty {
                Section { KeyringText(PhoneCopy.nothingWaiting, as: .meta) }
            }
            if !model.waiting.isEmpty {
                Section {
                    ForEach(model.waiting) { request in waitingCard(request) }
                } header: { KeyringText(PhoneCopy.waitingForYou, as: .sectionName) }
            }
            if !model.inUse.isEmpty {
                Section {
                    ForEach(model.inUse) { request in
                        if case let .approved(_, until) = request.state {
                            KeyringDeviceRow(symbol: "key.fill", name: request.login.site, detail: PhoneCopy.inUseDetail(request, until: until), nameFit: .siteName) {
                                KeyringButton(.plain(PhoneCopy.stop) { Task { await model.stop(request.id) } })
                            }
                        }
                    }
                } header: { KeyringText(PhoneCopy.inUse, as: .sectionName) }
            }
            if !earlier.isEmpty {
                Section {
                    ForEach(earlier) { request in
                        let (outcome, word) = PhoneCopy.outcome(request.state)
                        KeyringDeviceRow(symbol: "clock", name: request.login.site, detail: PhoneCopy.historyDetail(request), nameFit: .siteName) {
                            KeyringText(word, as: .meta, colour: outcome == .approved ? KeyringPalette.approve : outcome == .denied ? KeyringPalette.deny : nil)
                        }
                    }
                } header: { KeyringText(PhoneCopy.earlierToday, as: .sectionName) }
            }
            Section {} footer: { KeyringText(PhoneCopy.seenOnThisIPhone, as: .caption) }
        }
        .sheet(isPresented: $settingsShown) { PhoneSettingsView(model: model) }
    }

    /// The request in place: Deny and Approve, and Deny and Explain, which opens the reply box.
    private func waitingCard(_ request: AccessRequest) -> some View {
        let busy = model.answering != nil
        return KeyringApprovalCard(
            lead: PhoneCopy.wants(request.agent),
            subject: request.login.site, detail: request.login.account.isEmpty ? nil : request.login.account,
            reason: request.agentReason.isEmpty ? nil : request.agentReason,
            approve: .approve(PhoneCopy.approve, isEnabled: !busy) { Task { await model.approve(request.id) } },
            deny: .deny(PhoneCopy.deny, isEnabled: !busy) { Task { await model.deny(request.id) } },
            explain: .denyLink(PhoneCopy.denyAndExplain, isEnabled: !busy) { model.explain(request.id) },
            footer: model.snapshot.undelivered.contains(request.id) ? PhoneCopy.notDeliveredYet : nil)
    }

    private var earlier: [AccessRequest] {
        model.finished.filter { Calendar.current.isDateInToday($0.askedAt) }
    }
}

/// Paper draws the tab icons as outlines; a SwiftUI symbol in a tab bar is always filled.
enum TabGlyph {
    @MainActor static func outline(_ name: String) -> UIImage {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))!
            .withRenderingMode(.alwaysTemplate)
    }
}

/// The keyhole alone, for the Logins tab, drawn as a template so the tab bar tints it.
enum KeyholeGlyph {
    @MainActor static let image: UIImage = {
        let size = CGSize(width: 20, height: 20)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            // The icon's figure, from its 80 × 80 view box at (10, 12).
            let s = size.width / 80
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x - 10) * s, y: (y - 12) * s) }
            UIBezierPath(ovalIn: CGRect(origin: p(28.5, 17), size: CGSize(width: 43 * s, height: 43 * s))).fill()
            let body = UIBezierPath()
            body.move(to: p(40.2, 51.5)); body.addLine(to: p(59.8, 51.5)); body.addLine(to: p(67.2, 81.9))
            body.addQuadCurve(to: p(64.1, 85.9), controlPoint: p(67.8, 85.9))
            body.addLine(to: p(35.9, 85.9))
            body.addQuadCurve(to: p(32.8, 81.9), controlPoint: p(32.2, 85.9))
            body.close(); body.fill()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()
}

/// Passwords: what Ask, Automatic and Blocked mean, then every password with its rule.
struct PhoneLoginsView: View {
    let model: PhoneModel
    @State private var query = ""

    var body: some View {
        PhoneList(title: PhoneCopy.passwords) {
            Section {
                KeyringText(PhoneCopy.askLegend, as: .meta)
                KeyringText(PhoneCopy.automaticLegend, as: .meta)
                KeyringText(PhoneCopy.blockedLegend, as: .meta)
            } header: { KeyringText(PhoneCopy.passwordsCount(model.snapshot.logins.count), as: .sectionName) }
            Section {
                ForEach(shown) { login in
                    KeyringDeviceRow(symbol: "key", name: login.site, detail: login.account.isEmpty ? nil : login.account, nameFit: .siteName) {
                        Menu {
                            ForEach([PhoneLogin.Rule.ask, .automatic, .blocked], id: \.self) { rule in
                                Button(PhoneCopy.rule(rule)) { Task { await model.setRule(rule, forLogin: login.id) } }
                            }
                        } label: {
                            KeyringText(PhoneCopy.rule(login.rule), as: .meta, colour: KeyringPalette.brand)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: PhoneCopy.search)
    }

    private var shown: [PhoneLogin] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let sorted = model.snapshot.logins.sorted { $0.site.localizedStandardCompare($1.site) == .orderedAscending }
        guard !q.isEmpty else { return sorted }
        return sorted.filter { $0.site.localizedCaseInsensitiveContains(q) || $0.account.localizedCaseInsensitiveContains(q) }
    }
}

/// Devices: where he approves, Add Apple Watch while a paired one is not added, and the other computers.
struct PhoneDevicesView: View {
    let model: PhoneModel
    @State private var removing: PhoneDevice?

    var body: some View {
        PhoneList(title: PhoneCopy.devices) {
            Section {
                ForEach(model.snapshot.devices.filter { $0.role == .approves }) { row($0) }
                if model.snapshot.watch.toAdd {
                    KeyringButton(.link(PhoneCopy.addAppleWatchRow) { Task { await model.addWatch(.open) } })
                }
            } header: { KeyringText(PhoneCopy.youApproveOn, as: .sectionName) }
            let computers = model.snapshot.devices.filter { $0.role == .asks }
            if !computers.isEmpty {
                Section {
                    ForEach(computers) { row($0) }
                } header: { KeyringText(PhoneCopy.agentsAskFrom, as: .sectionName) }
            }
        }
        .confirmationDialog(removing.map { PhoneCopy.removeQuestion($0.name) } ?? "", isPresented: removingShown,
                            titleVisibility: .visible, presenting: removing) { device in
            Button(PhoneCopy.remove, role: .destructive) { Task { await model.remove(device: device.id) } }
            Button(PhoneCopy.cancel, role: .cancel) {}
        } message: { device in Text(PhoneCopy.removeDetail(device, alsoAsks: alsoAsks(device))) }
    }

    /// Send Practice Request on the row; Remove by swiping it to the left, out of the way.
    private func row(_ device: PhoneDevice) -> some View {
        KeyringDeviceRow(symbol: symbol(device), name: device.isThisIPhone ? PhoneCopy.thisIPhone : device.name,
                         detail: device.role == .asks ? PhoneCopy.connected : device.detail) {
            if device.canPractice {
                KeyringButton(.link(PhoneCopy.practiceShort) {
                    Task { await model.sendPractice(to: device.isThisIPhone ? nil : device.id) }
                })
            }
        }
        .swipeActions(edge: .trailing) {
            if device.canRemove && !device.isThisIPhone {
                Button(PhoneCopy.remove, role: .destructive) { removing = device }
            }
        }
    }

    private func symbol(_ device: PhoneDevice) -> String {
        if device.role == .asks { return "desktopcomputer" }
        switch device.detail {
        case PhoneCopy.answersWithTap: return "applewatch"
        case PhoneCopy.answersWithTouchID: return "laptopcomputer"
        default: return "iphone"
        }
    }

    /// A Mac that approves and whose agents ask: one Remove takes both.
    private func alsoAsks(_ device: PhoneDevice) -> Bool {
        device.role == .approves && model.snapshot.devices.contains { $0.role == .asks && $0.name == device.name }
    }

    private var removingShown: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }
}

/// Paper, "On iPhone and Apple Watch", iPhone, Settings: Time Sensitive and Quiet Hours.
struct PhoneSettingsView: View {
    let model: PhoneModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let settings = model.snapshot.settings
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: binding(\.timeSensitive)) { KeyringText(PhoneCopy.timeSensitive) }
                } footer: { KeyringText(PhoneCopy.timeSensitiveDetail, as: .caption) }
                Section {
                    Toggle(isOn: binding(\.quietHours)) { KeyringText(PhoneCopy.quietHours) }
                        .disabled(!settings.timeSensitive)
                    if settings.quietHours && settings.timeSensitive {
                        DatePicker(selection: time(\.quietFrom), displayedComponents: .hourAndMinute) { KeyringText(PhoneCopy.from) }
                        DatePicker(selection: time(\.quietTo), displayedComponents: .hourAndMinute) { KeyringText(PhoneCopy.to) }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: KeyringSpace.s3) {
                        KeyringText(PhoneCopy.quietHoursDetail, as: .caption)
                        KeyringText(PhoneCopy.watchFollows, as: .caption)
                    }
                }
            }
            .navigationTitle(PhoneCopy.settings)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(PhoneCopy.done) { dismiss() } } }
        }
        .environment(\.locale, Locale(identifier: "en_GB"))
    }

    private func binding(_ path: WritableKeyPath<PhoneSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.snapshot.settings[keyPath: path] }, set: { value in
            var next = model.snapshot.settings
            next[keyPath: path] = value
            Task { await model.setSettings(next) }
        })
    }

    /// Minutes after midnight, as a time of day for the picker.
    private func time(_ path: WritableKeyPath<PhoneSettings, Int>) -> Binding<Date> {
        let calendar = Calendar.current
        return Binding(get: {
            calendar.date(bySettingHour: model.snapshot.settings[keyPath: path] / 60, minute: model.snapshot.settings[keyPath: path] % 60,
                          second: 0, of: .now) ?? .now
        }, set: { date in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            var next = model.snapshot.settings
            next[keyPath: path] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            Task { await model.setSettings(next) }
        })
    }
}
#endif
