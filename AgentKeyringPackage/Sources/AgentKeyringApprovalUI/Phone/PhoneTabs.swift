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
            if let stage = model.snapshot.firstRun {
                PhoneFirstRunView(stage: stage, model: model)
            } else {
                TabView(selection: $model.tab) {
                    Tab(value: PhoneTab.activity) { PhoneActivityView(model: model) } label: {
                        Label { Text(PhoneCopy.activity) } icon: { Image(uiImage: TabGlyph.outline("clock")) }
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
            PhoneRequestView(model: model, request: request)
        }
        .sheet(item: practiceShown) { request in
            PhoneRequestView(model: model, request: request, practice: true).interactiveDismissDisabled()
        }
        .sheet(item: ruleChangeShown) { change in
            let lines = PhoneCopy.ruleChangeLines(change)
            PhoneSimpleRequestView(model: model, lead: PhoneCopy.ruleChangeLead(change), title: PhoneCopy.ruleChangeTitle(change),
                                   detail: PhoneCopy.ruleChangeAccount(change), change: lines.change, allows: lines.allows,
                                   footnote: PhoneCopy.ruleChangeFootnote(change), dismissable: true,
                                   approve: { await model.approveRuleChange(change.id) }, deny: { await model.denyRuleChange(change.id) })
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

    /// The practice request comes up by itself once it arrives.
    private var practiceShown: Binding<AccessRequest?> {
        Binding(get: { model.snapshot.firstRun == .practice ? model.snapshot.practiceRequest : nil }, set: { _ in })
    }

    /// A rule change opens from its notification or from Show in Activity, as a login request does.
    private var ruleChangeShown: Binding<PhoneRuleProposal?> {
        Binding(get: { model.shownRequestID.flatMap(model.ruleChange(id:)).flatMap { $0.state.isWaitingForYou ? $0 : nil } },
                set: { model.shownRequestID = $0?.id })
    }

    private var deviceShown: Binding<PhoneDeviceRequest?> {
        Binding(get: { model.snapshot.firstRun == nil || model.snapshot.firstRun == .done ? model.snapshot.deviceRequest : nil }, set: { _ in })
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

struct PhoneActivityView: View {
    let model: PhoneModel

    @State private var settingsShown = false

    var body: some View {
        requests
            .sheet(isPresented: $settingsShown) { PhoneSettingsView(model: model) }
    }

    private var isEmpty: Bool { model.snapshot.requests.isEmpty && model.snapshot.ruleChanges.isEmpty }

    @ViewBuilder private var notices: some View {
        ForEach(model.snapshot.notices) { notice in
            Section {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        if notice == .addAppleWatch {
                            Text(PhoneCopy.addAppleWatch).font(.body.weight(.semibold)).foregroundStyle(Phone.ink)
                        }
                        Text(PhoneCopy.notice(notice)).font(.subheadline).foregroundStyle(notice == .addAppleWatch ? Phone.ink2 : Phone.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if notice.dismissable {
                        Button { Task { await model.dismiss(notice) } } label: {
                            Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Phone.ink2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(PhoneCopy.close)
                    }
                }
                .padding(.vertical, 2)
                .phoneRow()
            }
        }
    }

    private var requests: some View {
        PhoneList(title: PhoneCopy.activity, trailing: (PhoneCopy.settings, { settingsShown = true })) {
            notices
            if isEmpty {
                Section {
                    VStack(spacing: 4) {
                        Text(PhoneCopy.noRequestsYet).font(.title3.weight(.semibold)).foregroundStyle(Phone.ink)
                        Text(PhoneCopy.noRequestsDetail).font(.subheadline).foregroundStyle(Phone.ink2)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 150)
                    .listRowBackground(Color.clear)
                }
            } else {
                activity
            }
        }
    }

    @ViewBuilder private var activity: some View {
            Section {
                if model.waiting.isEmpty && model.waitingRuleChanges.isEmpty {
                    Text(PhoneCopy.nothingWaiting).font(.body).foregroundStyle(Phone.ink2).phoneRow()
                }
                ForEach(model.waitingRuleChanges) { change in
                    HStack(spacing: 10) {
                        TwoLines(title: PhoneCopy.ruleChangeTitle(change), detail: PhoneCopy.ruleChangeWaitingDetail(change))
                        Button(PhoneCopy.show) { model.shownRequestID = change.id }
                            .buttonStyle(RowButtonStyle(fill: Phone.ink, text: Phone.surface))
                    }
                    .phoneRow()
                }
                ForEach(model.waiting) { request in
                    HStack(spacing: 10) {
                        TwoLines(title: request.login.site, detail: PhoneCopy.waitingDetail(request.agent))
                        Button(PhoneCopy.show) { model.shownRequestID = request.id }
                            .buttonStyle(RowButtonStyle(fill: Phone.ink, text: Phone.surface))
                    }
                    .phoneRow()
                }
            } header: { SectionTitle(PhoneCopy.waitingForYou) }

            if !model.inUse.isEmpty {
                Section {
                    ForEach(model.inUse) { request in
                        HStack(spacing: 10) {
                            if case let .approved(_, until) = request.state {
                                TwoLines(title: request.login.site, detail: PhoneCopy.inUseDetail(request.agent, until: until))
                            }
                            Button(PhoneCopy.stop) { Task { await model.stop(request.id) } }
                                .buttonStyle(RowButtonStyle(fill: Phone.fill, text: Phone.ink))
                        }
                        .phoneRow()
                    }
                } header: { SectionTitle(PhoneCopy.inUse) }
            }

            ForEach(days, id: \.title) { day in
                Section {
                    ForEach(day.entries) { entry in
                        HStack(spacing: 10) {
                            TwoLines(title: entry.title, detail: entry.detail)
                            OutcomeMark(state: entry.state)
                        }
                        .phoneRow()
                    }
                } header: { SectionTitle(day.title) }
            }
    }

    /// A finished request or rule change, as one line of history.
    private struct Entry: Identifiable {
        let id: String
        let title: String
        let detail: String
        let state: AccessRequestState
        let at: Date
    }

    private var days: [(title: String, entries: [Entry])] {
        let entries = model.finished.map { Entry(id: $0.id, title: $0.login.site, detail: PhoneCopy.historyDetail($0), state: $0.state, at: $0.askedAt) }
            + model.finishedRuleChanges.map { Entry(id: $0.id, title: PhoneCopy.ruleChangeTitle($0), detail: PhoneCopy.ruleChangeHistoryDetail($0),
                                                     state: $0.state, at: $0.askedAt) }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.at) }
        return grouped.keys.sorted(by: >).map { (PhoneCopy.day($0), grouped[$0]!.sorted { $0.at > $1.at }) }
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
                ForEach(shown) { login in
                    HStack(spacing: 10) {
                        TwoLines(title: login.site, detail: login.account)
                        Menu {
                            ForEach([PhoneLogin.Rule.ask, .askOnIPhoneOrWatch, .automatic, .blocked], id: \.self) { rule in
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
        } message: { device in Text(PhoneCopy.removeDetail(device)) }
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
                        if !device.isThisIPhone {
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
                    if settings.quietHours {
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
