// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The app after first run (Paper, "On iPhone and Apple Watch"): Activity,
// Passwords and Devices, the same three things as the Mac.

#if os(iOS)
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
                .tint(Phone.ink)
            }
        }
        .task { await model.followUpdates() }
        .alert(model.failure ?? "", isPresented: failureShown) { Button(PhoneCopy.ok) { model.dismissFailure() } }
        .sheet(item: shownRequest) { request in
            PhoneRequestView(model: model, request: request, practice: request.isPractice)
        }
        .sheet(item: practiceShown) { request in
            PhoneRequestView(model: model, request: request, practice: true).interactiveDismissDisabled()
        }
        .sheet(item: deviceShown) { device in
            PhoneSimpleRequestView(model: model, lead: PhoneCopy.addWatchLead, title: device.name, detail: device.detail,
                                   footnote: PhoneCopy.watchFootnote, stackedDeny: true, approve: { await model.approveDevice(device.id) },
                                   deny: { await model.denyDevice(device.id) })
        }
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { model.failure != nil && model.shownRequestID == nil }, set: { if !$0 { model.dismissFailure() } })
    }

    /// The practice request, while first run has it open.
    private var practiceShown: Binding<AccessRequest?> {
        Binding(get: { model.snapshot.practiceRequest }, set: { _ in })
    }


    private var deviceShown: Binding<PhoneDeviceRequest?> {
        Binding(get: { [.finished, .addWatch].contains(model.snapshot.firstRun) ? model.snapshot.deviceRequest : nil }, set: { _ in })
    }

    private var shownRequest: Binding<AccessRequest?> {
        Binding(get: { model.shownRequestID.flatMap(model.request(id:)).flatMap { $0.state.isWaitingForYou ? $0 : nil } },
                set: { model.shownRequestID = $0?.id })
    }
}

/// A grouped list on Paper's grey page, with Paper's section headings.
private struct PhoneList<Content: View>: View {
    let title: String
    /// A text button at the top right: Activity's Settings.
    var trailing: (label: String, action: () -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            List { content }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Phone.page)
                .listSectionSpacing(14)
                .navigationTitle(title)
                .toolbar {
                    if let trailing {
                        ToolbarItem(placement: .topBarTrailing) { Button(trailing.label, action: trailing.action) }
                    }
                }
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(Phone.ink2).textCase(nil)
    }
}

/// A site or device name over one line of detail.
private struct TwoLines: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.body.weight(.semibold)).foregroundStyle(Phone.ink)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(Phone.ink2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func phoneRow() -> some View {
        frame(minHeight: 40)
            .listRowBackground(Phone.surface)
            .listRowSeparatorTint(Phone.line)
    }
}

/// Home (Paper, "iPhone every day"): whether everything works, what needs an answer, what is in use, earlier today.
struct PhoneHomeView: View {
    let model: PhoneModel

    @State private var settingsShown = false

    var body: some View {
        PhoneList(title: PhoneCopy.appName, trailing: (PhoneCopy.settings, { settingsShown = true })) {
            status
            if !model.waiting.isEmpty {
                Section {
                    ForEach(model.waiting) { request in waitingCard(request).phoneRow() }
                } header: { SectionTitle(PhoneCopy.needsYourAnswer) }
            }
            if !model.inUse.isEmpty {
                Section {
                    ForEach(model.inUse) { request in
                        HStack(spacing: 10) {
                            if case let .approved(_, until) = request.state {
                                TwoLines(title: request.login.site, detail: PhoneCopy.inUseDetail(request, until: until))
                            }
                            Button(PhoneCopy.stop) { Task { await model.stop(request.id) } }
                                .buttonStyle(RowButtonStyle(fill: Phone.fill, text: Phone.ink))
                        }
                        .phoneRow()
                    }
                } header: { SectionTitle(PhoneCopy.inUse) }
            }
            if !earlier.isEmpty {
                Section {
                    ForEach(earlier) { request in
                        HStack(spacing: 10) {
                            TwoLines(title: request.login.site, detail: PhoneCopy.historyDetail(request))
                            OutcomeMark(state: request.state)
                        }
                        .phoneRow()
                    }
                } header: { SectionTitle(PhoneCopy.earlierToday) }
            }
        }
        .sheet(isPresented: $settingsShown) { PhoneSettingsView(model: model) }
    }

    /// Ready, or the one line that says what is wrong; Send Practice Request either way.
    private var status: some View {
        let problem = model.snapshot.notices.first { $0 != .addAppleWatch }
        let computers = model.snapshot.devices.filter { $0.role == .asks }.map(\.name)
        let mac = model.snapshot.devices.contains { $0.role == .approves && $0.detail == PhoneCopy.answersWithTouchID }
        let watch = model.snapshot.devices.contains { $0.role == .approves && $0.detail == PhoneCopy.answersWithTap }
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(problem == nil ? Phone.approve : Phone.noAnswer).frame(width: 9, height: 9)
                    Text(problem == nil ? PhoneCopy.homeReady : PhoneCopy.notice(problem!)).font(.body.weight(.semibold)).foregroundStyle(Phone.ink)
                }
                if problem == nil {
                    Text(PhoneCopy.homeReadyDetail(computers: computers, watch: watch, mac: mac)).font(.subheadline).foregroundStyle(Phone.ink2)
                }
                Button(PhoneCopy.sendPractice) { Task { await model.sendPractice() } }
                    .buttonStyle(RowButtonStyle(fill: Phone.fill, text: Phone.ink))
                    .padding(.top, 2)
            }
            .padding(.vertical, 6)
            .phoneRow()
        }
    }

    /// The request in place: who, the site, the reason, then Deny… (the reply box) and Approve.
    private func waitingCard(_ request: AccessRequest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(PhoneCopy.homeDetail(request)).font(.footnote).foregroundStyle(Phone.ink2).lineLimit(1)
            Text(request.login.site).font(.title3.bold()).foregroundStyle(Phone.ink).lineLimit(1).minimumScaleFactor(0.6)
            if !request.agentReason.isEmpty {
                Text(PhoneCopy.quoted(request.agentReason)).font(.subheadline).foregroundStyle(Phone.ink).lineLimit(3)
            }
            HStack(spacing: 8) {
                Button(PhoneCopy.denyEllipsis) { model.shownRequestID = request.id }
                    .buttonStyle(PillButtonStyle(fill: Phone.fill, text: Phone.deny, height: 40))
                Button(PhoneCopy.approve) { Task { await model.approve(request.id) } }
                    .buttonStyle(PillButtonStyle(fill: Phone.approve, height: 40))
            }
            .disabled(model.answering != nil)
            .padding(.top, 6)
        }
        .padding(.vertical, 6)
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

private struct OutcomeMark: View {
    let state: AccessRequestState

    var body: some View {
        let (outcome, word) = PhoneCopy.outcome(state)
        HStack(spacing: 6) {
            Circle()
                .fill(outcome == .approved ? Phone.approve : outcome == .denied ? Phone.deny : Phone.noAnswer)
                .frame(width: 8, height: 8)
            Text(word).font(.subheadline).foregroundStyle(Phone.ink)
        }
        .fixedSize()
    }
}

struct PhoneLoginsView: View {
    let model: PhoneModel
    @State private var query = ""

    var body: some View {
        PhoneList(title: PhoneCopy.passwords) {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(PhoneCopy.passwordsCount(model.snapshot.logins.count)).font(.subheadline).foregroundStyle(Phone.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        meaning(PhoneCopy.rule(.ask), PhoneCopy.askMeans)
                        meaning(PhoneCopy.rule(.automatic), PhoneCopy.automaticMeans)
                        meaning(PhoneCopy.rule(.blocked), PhoneCopy.blockedMeans)
                    }
                }
                .padding(.vertical, 6)
                .phoneRow()
            }
            Section {
                ForEach(shown) { login in
                    HStack(spacing: 10) {
                        TwoLines(title: login.site, detail: login.account)
                        Menu {
                            ForEach([PhoneLogin.Rule.ask, .automatic, .blocked], id: \.self) { rule in
                                Button(PhoneCopy.rule(rule)) { Task { await model.setRule(rule, forLogin: login.id) } }
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Text(PhoneCopy.rule(login.rule))
                                Image(systemName: "chevron.down").font(.caption.weight(.bold))
                            }
                            .font(.subheadline).foregroundStyle(Phone.ink2)
                        }
                        .fixedSize()
                    }
                    .phoneRow()
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: PhoneCopy.search)
    }

    private func meaning(_ rule: String, _ means: String) -> some View {
        (Text(rule + ": ").fontWeight(.semibold) + Text(means)).font(.footnote).foregroundStyle(Phone.ink)
    }

    private var shown: [PhoneLogin] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let sorted = model.snapshot.logins.sorted { $0.site.localizedStandardCompare($1.site) == .orderedAscending }
        guard !q.isEmpty else { return sorted }
        return sorted.filter { $0.site.localizedCaseInsensitiveContains(q) || $0.account.localizedCaseInsensitiveContains(q) }
    }
}

struct PhoneDevicesView: View {
    let model: PhoneModel
    @State private var removing: PhoneDevice?

    var body: some View {
        PhoneList(title: PhoneCopy.devices) {
            section(PhoneCopy.youApproveOn, role: .approves)
            section(PhoneCopy.agentsAskFrom, role: .asks)
        }
        .confirmationDialog(removing.map { PhoneCopy.removeQuestion($0.name) } ?? "", isPresented: removingShown,
                            titleVisibility: .visible, presenting: removing) { device in
            Button(PhoneCopy.remove, role: .destructive) { Task { await model.remove(device: device.id) } }
            Button(PhoneCopy.cancel, role: .cancel) {}
        } message: { device in Text(PhoneCopy.removeDetail(device, alsoAsks: alsoAsks(device))) }
    }

    /// A Mac that approves and whose agents ask: one Remove takes both.
    private func alsoAsks(_ device: PhoneDevice) -> Bool {
        device.role == .approves && model.snapshot.devices.contains { $0.role == .asks && $0.name == device.name }
    }

    private var removingShown: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    @ViewBuilder private func section(_ title: String, role: PhoneDevice.Role) -> some View {
        let rows = model.snapshot.devices.filter { $0.role == role }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { device in
                    HStack(spacing: 10) {
                        TwoLines(title: device.isThisIPhone ? PhoneCopy.thisIPhone : device.name, detail: device.detail)
                        if device.canPractice {
                            Button(PhoneCopy.practiceShort) { Task { await model.sendPractice(to: device.id) } }
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Phone.accent)
                                .buttonStyle(.borderless)
                        }
                        if device.canRemove && !device.isThisIPhone {
                            Button(PhoneCopy.remove) { removing = device }
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Phone.deny)
                                .buttonStyle(.borderless)
                        }
                    }
                    .phoneRow()
                }
            } header: { SectionTitle(title) }
        }
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
                    Toggle(PhoneCopy.timeSensitive, isOn: binding(\.timeSensitive)).tint(Phone.approve)
                } footer: { Text(PhoneCopy.timeSensitiveDetail) }
                Section {
                    Toggle(PhoneCopy.quietHours, isOn: binding(\.quietHours)).tint(Phone.approve)
                        .disabled(!settings.timeSensitive)
                    if settings.quietHours && settings.timeSensitive {
                        DatePicker(PhoneCopy.from, selection: time(\.quietFrom), displayedComponents: .hourAndMinute)
                        DatePicker(PhoneCopy.to, selection: time(\.quietTo), displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(PhoneCopy.quietHoursDetail)
                        Text(PhoneCopy.watchFollows)
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
