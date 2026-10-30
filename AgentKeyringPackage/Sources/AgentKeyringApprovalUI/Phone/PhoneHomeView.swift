// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The iPhone app is one screen: what is waiting for you, what agents are
// using now, and what happened. A waiting request opens over it.

#if os(iOS)
import SwiftUI

public struct PhoneRootView: View {
    @Bindable var model: PhoneKeyringModel
    @State private var path: [String]

    public init(model: PhoneKeyringModel, openRequestID: String? = nil) {
        self.model = model
        _path = State(initialValue: openRequestID.map { [$0] } ?? [])
    }

    public var body: some View {
        NavigationStack(path: $path) {
            PhoneHomeView(model: model)
                .navigationDestination(for: String.self) { id in
                    if let request = model.request(id: id) {
                        PhoneRequestDetailView(model: model, request: request)
                    }
                }
        }
        .tint(KeyringColour.signal)
        .sheet(item: presentedRequest) { request in
            PhoneRequestView(model: model, requestID: request.id)
        }
        .sheet(isPresented: $model.isShowingSettings) {
            PhoneSettingsView(model: model)
        }
    }

    private var presentedRequest: Binding<AccessRequest?> {
        Binding(
            get: { model.presentedRequestID.flatMap(model.request(id:)) },
            set: { model.presentedRequestID = $0?.id }
        )
    }
}

struct PhoneHomeView: View {
    let model: PhoneKeyringModel

    var body: some View {
        Group {
            switch model.passwords {
            case .notImported, .importing, .importFailed:
                PhoneImportView(model: model)
            case .imported:
                requestList.navigationTitle("Agent Keyring")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { model.isShowingSettings = true }
            }
        }
    }

    private var requestList: some View {
        List {
            if case let .unreachable(service, since) = model.connection {
                Section { UnreachableNotice(service: service, since: since) }
            }

            if !model.waiting.isEmpty {
                Section {
                    ForEach(model.waiting) { request in
                        Button { model.presentedRequestID = request.id } label: {
                            WaitingRow(request: request)
                        }
                        .buttonStyle(.plain)
                    }
                } header: { SectionHeading("Waiting for you") }
            }

            if !model.inUse.isEmpty {
                Section {
                    ForEach(model.inUse) { request in
                        NavigationLink(value: request.id) {
                            InUseRow(request: request) { Task { await model.endAccess(request.id) } }
                        }
                    }
                } header: { SectionHeading("In use now") }
            }

            if model.waiting.isEmpty && model.inUse.isEmpty {
                Section { NothingWaiting() }
            }

            ForEach(historyDays, id: \.title) { day in
                Section {
                    ForEach(day.requests) { request in
                        NavigationLink(value: request.id) { HistoryRow(request: request) }
                    }
                } header: { SectionHeading(day.title) }
            }

            if case let .imported(count, at) = model.passwords {
                Section { PasswordsFooter(count: count, importedAt: at) }
                    .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }

    private var historyDays: [(title: String, requests: [AccessRequest])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: model.finished) { calendar.startOfDay(for: $0.askedAt) }
        return grouped.keys.sorted(by: >).map { day in
            let title = calendar.isDateInToday(day) ? "Today"
                : calendar.isDateInYesterday(day) ? "Yesterday"
                : day.formatted(.dateTime.weekday(.wide).day().month(.wide))
            return (title, grouped[day, default: []].sorted { $0.askedAt > $1.askedAt })
        }
    }
}

struct SectionHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.primary)
            .textCase(nil)
    }
}

private struct WaitingRow: View {
    let request: AccessRequest

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle().fill(KeyringColour.signal).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(request.login.site).font(.title3.weight(.semibold))
                Text("\(request.agent.name) · \(request.agent.machine)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if case let .waitingForYou(until) = request.state {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(AccessRequestCopy.remaining(until: until, now: context.date))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(KeyringColour.signal)
                }
            }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
    }
}

private struct InUseRow: View {
    let request: AccessRequest
    let end: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(request.login.site).font(.body.weight(.semibold))
                Text("\(request.agent.name) · \(request.agent.machine)")
                    .font(.subheadline).foregroundStyle(.secondary)
                if case let .approved(_, until) = request.state {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(AccessRequestCopy.minutesLeft(until: until, now: context.date))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(KeyringColour.approveText)
                    }
                }
            }
            Spacer()
            Button(AccessRequestCopy.endNow, action: end)
                .buttonStyle(.borderless)
                .font(.body.weight(.medium))
                .foregroundStyle(KeyringColour.denyText)
        }
        .padding(.vertical, 4)
    }
}

private struct HistoryRow: View {
    let request: AccessRequest

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(AccessRequestCopy.clock(request.askedAt))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.login.site).font(.body)
                Text("\(request.agent.name) · \(request.agent.machine)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Text(AccessRequestCopy.outcomeWord(request.state))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(outcomeColour(request.state) ?? .secondary)
        }
    }
}

private struct NothingWaiting: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing waiting")
                .font(.title3.weight(.semibold))
            Text("When an agent asks for a login and you're away from your Mac, it appears here and on your Lock Screen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
        .listRowSeparator(.hidden)
    }
}

private struct UnreachableNotice: View {
    let service: String
    let since: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(KeyringColour.denyText)
            VStack(alignment: .leading, spacing: 4) {
                Text("Can't reach Agent Keyring on \(service)")
                    .font(.body.weight(.semibold))
                Text("Since \(AccessRequestCopy.clock(since)). Requests can't reach you until it's back. Check Tailscale is on. Retrying.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .listRowSeparator(.hidden)
    }
}

private struct PasswordsFooter: View {
    let count: Int
    let importedAt: Date

    var body: some View {
        Text("\(count) logins · imported \(importedAt.formatted(.relative(presentation: .named)))")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
}
#endif
