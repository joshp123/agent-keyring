// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The app after first run (Paper, "On the iPhone and Watch"): Activity,
// Logins and Devices, the same three things as the Mac.

#if os(iOS)
import SwiftUI

public struct PhoneRootView: View {
    @Bindable var model: PhoneModel

    public init(model: PhoneModel) { self.model = model }

    public var body: some View {
        Group {
            if model.snapshot.setup.isReady {
                TabView(selection: $model.tab) {
                    Tab(value: PhoneTab.activity) { PhoneActivityView(model: model) } label: {
                        Label { Text(PhoneCopy.activity) } icon: { Image(uiImage: TabGlyph.outline("clock")) }
                    }
                    Tab(value: PhoneTab.logins) { PhoneLoginsView(model: model) } label: {
                        Label { Text(PhoneCopy.logins) } icon: { Image(uiImage: KeyholeGlyph.image) }
                    }
                    Tab(value: PhoneTab.devices) { PhoneDevicesView(model: model) } label: {
                        Label { Text(PhoneCopy.devices) } icon: { Image(uiImage: TabGlyph.outline("iphone")) }
                    }
                }
                .tint(Phone.ink)
            } else {
                PhoneSetupList(setup: model.snapshot.setup, model: model)
            }
        }
        .task { await model.followUpdates() }
        .alert(model.failure ?? "", isPresented: failureShown) { Button(PhoneCopy.ok) { model.dismissFailure() } }
        .sheet(item: shownRequest) { request in
            PhoneRequestView(model: model, request: request)
        }
        .sheet(isPresented: testShown) {
            PhoneSimpleRequestView(model: model, lead: PhoneCopy.testFrom, title: PhoneCopy.testTitle, detail: PhoneCopy.noLoginUsed,
                                   footnote: PhoneCopy.testFootnote, approve: { await model.approveTest() }, deny: { await model.denyTest() })
        }
        .sheet(item: deviceShown) { device in
            PhoneSimpleRequestView(model: model, lead: PhoneCopy.newDevice, title: device.name, detail: device.detail,
                                   footnote: PhoneCopy.watchFootnote, approve: { await model.approveDevice(device.id) },
                                   deny: { await model.denyDevice(device.id) })
        }
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { model.failure != nil && model.shownRequestID == nil }, set: { if !$0 { model.dismissFailure() } })
    }

    private var testShown: Binding<Bool> {
        Binding(get: { model.snapshot.testRequest != nil && model.shownRequestID == nil }, set: { _ in })
    }

    private var deviceShown: Binding<PhoneDeviceRequest?> {
        Binding(get: { model.snapshot.testRequest == nil ? model.snapshot.deviceRequest : nil }, set: { _ in })
    }

    private var shownRequest: Binding<AccessRequest?> {
        Binding(get: { model.shownRequestID.flatMap(model.request(id:)).flatMap { $0.state.isWaitingForYou ? $0 : nil } },
                set: { model.shownRequestID = $0?.id })
    }
}

/// A grouped list on Paper's grey page, with Paper's section headings.
private struct PhoneList<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            List { content }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Phone.page)
                .listSectionSpacing(14)
                .navigationTitle(title)
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

    var body: some View {
        // Until the first request, the finished first-run list says it is ready.
        if model.snapshot.requests.isEmpty && !model.snapshot.setup.lines.isEmpty {
            PhoneSetupList(setup: model.snapshot.setup, model: model)
        } else {
            requests
        }
    }

    private var requests: some View {
        PhoneList(title: PhoneCopy.activity) {
            Section {
                if model.waiting.isEmpty {
                    Text(PhoneCopy.nothingWaiting).font(.body).foregroundStyle(Phone.ink2).phoneRow()
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
                    ForEach(day.requests) { request in
                        HStack(spacing: 10) {
                            TwoLines(title: request.login.site, detail: PhoneCopy.historyDetail(request))
                            OutcomeMark(state: request.state)
                        }
                        .phoneRow()
                    }
                } header: { SectionTitle(day.title) }
            }
        }
    }

    private var days: [(title: String, requests: [AccessRequest])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: model.finished) { calendar.startOfDay(for: $0.askedAt) }
        return grouped.keys.sorted(by: >).map { (PhoneCopy.day($0), grouped[$0]!.sorted { $0.askedAt > $1.askedAt }) }
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
        PhoneList(title: PhoneCopy.logins) {
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
#endif
