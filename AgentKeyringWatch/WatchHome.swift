// Written by AI on 2026.11.21 by model Claude Opus 5.5.
//
// The Watch app's own screen: the page for where setup stands, or "In use",
// from AgentKeyringWatchUI, with what each button does.

import AgentKeyringWatchCore
import AgentKeyringWatchUI
import SwiftUI
import UserNotifications

struct WatchHome: View {
    let model: WatchModel
    @State private var practiceFailed = false
    @State private var addFailed = false

    var body: some View {
        #if DEBUG
        // For looking at the request card in the simulator: -SampleCard YES (-SamplePractice YES for the practice's).
        if UserDefaults.standard.bool(forKey: "SampleCard") { SampleCard() } else { home }
        #else
        home
        #endif
    }

    private var home: some View {
        // "In use" while something is in use; otherwise the page for where setup stands.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let inUse = model.inUse.filter { $0.until > context.date }
            if model.setup == .ready && !inUse.isEmpty {
                WatchInUsePage(items: inUse) { await WatchLink.shared.stop($0) }
            } else {
                WatchSetupPage(setup: model.setup, practiceFailed: practiceFailed, addFailed: addFailed) { await act($0) }
            }
        }
        .onChange(of: model.setup) { _, next in
            if next != .addedOfferPractice { practiceFailed = false }
            if next != .readyToAdd { addFailed = false }
        }
    }

    private func act(_ action: WatchSetupAction) async {
        switch action {
        case .add:
            addFailed = false
            let started = await WatchLink.shared.add()
            addFailed = !started
        case .cancelAdd:
            addFailed = false
            await WatchLink.shared.cancelAdd()
        case .allowNotifications:
            // watchOS's own question, only once the iPhone has added this Apple Watch.
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await WatchLink.shared.refreshSetup()
            await WatchLink.shared.sendHandOver()
        case .checkAgain: await WatchLink.shared.refreshSetup()
        case .tryPractice: practiceFailed = !(await WatchLink.shared.askForPractice())
        case .cancelPractice:
            practiceFailed = false
            await WatchLink.shared.cancelPractice()
        case .done:
            practiceFailed = false
            await WatchLink.shared.practiceOfferDone()
        }
    }
}

#if DEBUG
private struct SampleCard: View {
    @State private var model = RequestModel()
    var body: some View { RequestView(model: model).onAppear { model.show(["akrSample": true]) } }
}
#endif
