// Written by AI on 2026.11.18 by model Claude Opus 5.5; rebuilt on 2026.11.26
// by model gemini-4-neon; split into its own file on 2026.11.27 by model claude opus 5.5.
//
// The iPhone app's root: first run, or the four native tabs (Home, Passwords,
// Devices, Settings) on iOS 27 Liquid Glass, plus the request, Add Watch and
// Settings sheets.

#if os(iOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

public struct PhoneRootView: View {
    @Bindable var model: PhoneModel
    @State private var presentedSheetItem: PhoneSheetItem?

    public init(model: PhoneModel) { self.model = model }

    public var body: some View {
        Group {
            if model.snapshot.firstRun != .finished {
                PhoneFirstRunView(stage: model.snapshot.firstRun, model: model)
            } else {
                TabView(selection: $model.tab) {
                    Tab(PhoneCopy.home, systemImage: "clock.fill", value: PhoneTab.home) {
                        PhoneHomeView(model: model)
                    }
                    .badge(model.waiting.count)

                    Tab(PhoneCopy.passwords, systemImage: "key.fill", value: PhoneTab.logins) {
                        PhoneLoginsView(model: model)
                    }

                    Tab(PhoneCopy.devices, systemImage: "iphone", value: PhoneTab.devices) {
                        PhoneDevicesView(model: model)
                    }

                    Tab(PhoneCopy.settings, systemImage: "gearshape.fill", value: PhoneTab.settings) {
                        PhoneSettingsView(model: model, inTab: true)
                    }
                }
                .tint(KeyringPalette.brand)
            }
        }
        .tint(KeyringPalette.brand)
        .onAppear { KeyringFont.configureNavigationAppearance() }
        .task { await model.followUpdates() }
        .alert(model.failure ?? "", isPresented: failureShown) { Button(PhoneCopy.ok) { model.dismissFailure() } }
        .sheet(item: activeSheet) { item in
            Group {
                switch item {
                case let .request(id):
                    if let request = model.accessRequest(id: id) {
                        let mode = model.sheet.requestMode ?? .decide
                        NavigationStack {
                            PhoneRequestView(model: model, request: request, mode: mode, practice: request.isPractice)
                                .toolbar { requestBar(item: item, mode: mode) }
                        }
                        .interactiveDismissDisabled(mode == .approving || model.answering != nil)
                    } else {
                        let busy = model.answering != nil || model.isLoadingNotification(id)
                        NavigationStack {
                            KeyringPage(alignment: .centre, status: .waiting(PhoneCopy.approving)) { EmptyView() }
                                .toolbar { requestBar(item: item, mode: busy ? .approving : .decide) }
                        }
                        .interactiveDismissDisabled(busy)
                    }
                case .addWatch:
                    PhoneAddWatchView(flow: model.snapshot.addWatch, model: model).interactiveDismissDisabled()
                case .settings:
                    PhoneSettingsView(model: model)
                }
            }
            .tint(KeyringPalette.brand)
            .onAppear { presentedSheetItem = item }
        }
    }

    @ToolbarContentBuilder private func requestBar(item: PhoneSheetItem, mode: PhoneSheetMode) -> some ToolbarContent {
        switch mode {
        case .settled:
            ToolbarItem(placement: .topBarTrailing) {
                Button(PhoneCopy.done) { model.dismissSheet(expectedItem: item) }
            }
        case .explain:
            // Single Close button in top-left (matching .decide/.approving; Cancel lives inside the reply card).
            ToolbarItem(placement: .topBarLeading) {
                Button(PhoneCopy.close) { model.dismissSheet(expectedItem: item) }
                    .disabled(model.answering != nil)
            }
        case .decide, .approving:
            ToolbarItem(placement: .topBarLeading) {
                Button(PhoneCopy.close) { model.dismissSheet(expectedItem: item) }
                    .disabled(mode == .approving || model.answering != nil)
            }
        }
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { model.failure != nil && model.sheet.item == nil }, set: { if !$0 { model.dismissFailure() } })
    }

    private var activeSheet: Binding<PhoneSheetItem?> {
        Binding(
            get: { model.sheet.item },
            set: { next in
                if next == nil {
                    guard let dismissed = presentedSheetItem else { return }
                    presentedSheetItem = nil
                    model.dismissSheet(expectedItem: dismissed)
                }
            }
        )
    }
}

struct PhoneList<Content: View>: View {
    let title: String
    var onSettings: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            List { content }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(KeyringPalette.canvas)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    if let onSettings {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: onSettings) {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityLabel(PhoneCopy.settings)
                        }
                    }
                }
        }
    }
}
#endif
