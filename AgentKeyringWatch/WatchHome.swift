// Written by AI on 2026.11.21 by model Claude Opus 5.5.
//
// The Watch app's own screen: the page for where setup stands, or "In use",
// from AgentKeyringWatchUI, with what each button does.

import AgentKeyringSealing
import AgentKeyringWatchUI
import SwiftUI
import UserNotifications

struct WatchHome: View {
    let model: WatchModel
    @State private var practiceFailed = false
    @State private var addFailed = false

    var body: some View {
        Group {
            if model.setup == .ready && !model.inUse.isEmpty {
                WatchInUsePage(items: model.inUse) { await WatchLink.shared.stop($0) }
            } else {
                WatchSetupPage(setup: model.setup, practiceFailed: practiceFailed, addFailed: addFailed) { await act($0) }
            }
        }
        .onChange(of: model.setup) { _, next in
            if next != .addedOfferPractice { practiceFailed = false }
            if next != .readyToAdd { addFailed = false }
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.foregroundRequest != nil },
            set: { if !$0 { model.dismissForegroundRequest() } }
        )) {
            if let requestModel = model.foregroundRequest {
                RequestView(model: requestModel)
            }
        }
        .task(id: model.setup) {
            // Re-evaluate time-bounded states (Add offer expiry, preparing, practice wait) even if
            // a one-shot timer missed while watchOS suspended the app, and pick up any delivered
            // APNs practice notification if watchOS filed it quietly while the iPhone was unlocked.
            guard model.setup == .readyToAdd || model.setup == .preparing || model.setup == .practiceWaiting else { return }
            var ticks = 0
            while !Task.isCancelled {
                if model.setup == .practiceWaiting {
                    await model.pickUpDeliveredRequestNotification()
                    try? await Task.sleep(for: .seconds(1))
                    ticks += 1
                    if ticks % 10 == 0 {
                        await WatchLink.shared.refreshSetup()
                    }
                } else {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    await WatchLink.shared.refreshSetup()
                }
            }
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
