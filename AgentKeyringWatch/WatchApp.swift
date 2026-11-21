// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Agent Keyring on the Apple Watch. It sets itself up with nothing for the
// person to do but what Apple asks: it makes its keys, gets its push address
// and hands both to the iPhone, which adds it. Whichever app is opened first,
// or neither, the two finish setting up when they next meet.

import AgentKeyringProtocol
import AgentKeyringWatchCore
import LocalAuthentication
import OSLog
import SwiftUI
import UserNotifications
import WatchConnectivity
import WatchKit

let log = Logger(subsystem: "com.joshpalmer.AgentKeyring.Watch", category: "watch")

@main
struct AgentKeyringWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate

    init() {
        // A new install: removing the app cleared its own settings but not its keychain. The keys stay.
        if !UserDefaults.standard.bool(forKey: "installed") {
            WatchStore().delete()
            UserDefaults.standard.set(true, forKey: "installed")
        }
    }

    var body: some Scene {
        WindowGroup { WatchHome(model: WatchModel.shared) }
        WKNotificationScene(controller: RequestController.self, category: WatchWords.requestCategory)
    }
}

/// What the Watch's own screen shows: where setup stands, or what is in use.
@MainActor @Observable
final class WatchModel {
    static let shared = WatchModel()

    var inUse: [WatchInUse] = WatchStore().read().currentInUse
    var setup: WatchSetup = {
        #if DEBUG
        // For comparing screens with Paper in the simulator: -SampleSetup notifications.
        let samples: [String: WatchSetup] = ["no-passcode": .noPasscode, "set-up-iphone": .setUpIPhone, "start-on-iphone": .startOnIPhone,
                                             "ready-to-add": .readyToAdd, "preparing": .preparing,
                                             "notifications": .notifications, "notifications-off": .notificationsOff,
                                             "setting-up": .settingUpNotifications, "added": .addedOfferPractice,
                                             "practice-waiting": .practiceWaiting, "ready": .ready]
        if let name = UserDefaults.standard.string(forKey: "SampleSetup"), let sample = samples[name] { return sample }
        #endif
        let saved = WatchStore().read()
        return saved.lists((try? WatchKeys().keyID()) ?? "") ? .ready : saved.signedMembers != nil ? .startOnIPhone : .setUpIPhone
    }()
}

final class WatchDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([WatchDelegate.requestCategory])
        WatchLink.shared.activate()
        WKApplication.shared().registerForRemoteNotifications()
        #if DEBUG
        // For looking at the request card in the simulator: -AskNotifications YES.
        if UserDefaults.standard.bool(forKey: "AskNotifications") {
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        }
        #endif
    }

    func applicationDidBecomeActive() {
        Task {
            await WatchLink.shared.refreshSetup()
            await WatchLink.shared.sendHandOver()
        }
    }

    /// No notification actions of Apple's: Approve, Deny and Deny and Explain are our own three buttons in the
    /// request's card, one kind, and with no action of Apple's there is nothing for a Double Tap to choose.
    static let requestCategory = UNNotificationCategory(identifier: WatchWords.requestCategory, actions: [], intentIdentifiers: [])

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        WatchLink.shared.pushToken = deviceToken
        Task { await WatchLink.shared.refreshSetup(); await WatchLink.shared.sendHandOver() }
    }

    /// A silent push: a request was answered or ended. Its notification goes, and "In use" follows its outcome.
    func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> WKBackgroundFetchResult {
        guard (userInfo["aps"] as? [String: Any])?["alert"] == nil, let id = userInfo["id"] as? String else { return .noData }
        watchLog.note("notification", "removed", ["request": id, "by": "silent push"])
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        let same = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == id }.map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: same)
        let store = WatchStore()
        if let request = try? WatchRequest.from(userInfo: userInfo, keys: WatchKeys(), saved: store.read()) {
            store.write(store.read().noting(request))
            await WatchLink.shared.refreshSetup()
        }
        return .newData
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        log.error("No push address: \(error.localizedDescription, privacy: .public)")
        WatchLink.shared.lastProblem = "Apple gave no push address: \(error.localizedDescription)"
        Task { await WatchLink.shared.sendHandOver() }
    }

    /// The iPhone's hand-over can wake the Watch app in the background, even
    /// before the person has opened it.
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let task = task as? WKWatchConnectivityRefreshBackgroundTask {
                WatchLink.shared.activate()
                WatchLink.shared.whenIdle { task.setTaskCompletedWithSnapshot(false) }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    enum AnswerResult { case sent, alreadyAnswered, failed }

    /// Sends the answer from the request's card. The reply is the request's Lease: if another device's
    /// answer ended it first, that is the outcome.
    static func answer(_ request: WatchRequest, approve: Bool, words: String) async -> AnswerResult {
        watchLog.note("answer", "started", ["request": request.id, "choice": approve ? "approve" : words.isEmpty ? "deny" : "deny-with-words"])
        let saved = WatchStore().read()
        let mine = (try? WatchKeys().keyID()).flatMap { id in saved.signedMembers?.devices.first { $0.keyID == id }?.label }
        do {
            let lease: Agentkeyring_V2_Lease
            if approve {
                lease = try await WatchAnswers().approve(request)
                // In use on this Apple Watch until the approval ends.
                if lease.state == .approved, lease.notAfterUnixSeconds > 0, !request.isPractice {
                    let store = WatchStore()
                    store.write(store.read().addingInUse(WatchInUse(id: request.id, site: request.site, who: request.who,
                                                                    until: Date(timeIntervalSince1970: Double(lease.notAfterUnixSeconds)))))
                }
            } else {
                lease = try await WatchAnswers().deny(request, words: words)
            }
            if let mine, !lease.answeredBy.isEmpty, lease.answeredBy != mine {
                watchLog.note("answer", "already answered", ["request": request.id, "by": lease.answeredBy])
                return .alreadyAnswered
            }
            watchLog.note("answer", "sent", ["request": request.id])
            if request.isPractice, WatchStore().read().practiceAnswered != true {
                let store = WatchStore()
                var saved = store.read()
                saved.practiceAnswered = true
                saved.practiceOfferDone = true
                store.write(saved)
                await WatchLink.shared.sendHandOver()
                await WatchLink.shared.refreshSetup()
            }
            return .sent
        } catch {
            WatchLink.shared.report(problem: "\(approve ? "Approve" : "Deny") was not delivered: \(error)")
            return .failed
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Apple Watch's words on its own screen (Paper, "First run and the app", board "iPhone and Apple Watch").
enum WatchCopy {
    static func line(_ setup: WatchSetup) -> (title: String, detail: String) {
        switch setup {
        case .noPasscode: ("Set a passcode", "To approve from your wrist, set one in the Apple Watch app on your iPhone.")
        case .setUpIPhone: ("Agent Keyring", "Approve your AI agents’ password requests with a tap. Set up Agent Keyring on your iPhone first.")
        case .startOnIPhone: ("Start on your iPhone", "Open Agent Keyring on your iPhone, go to Devices, and tap Add Apple Watch.")
        case .readyToAdd: ("Add this Apple Watch?", "Your iPhone encrypts your passwords for this Apple Watch. Each request brings the one it needs.")
        case .preparing: ("Adding this Apple Watch", "Your iPhone is finishing. Keep it nearby.")
        case .addedOfferPractice: ("Apple Watch added", "Try a practice request to see one on your wrist.")
        case .practiceWaiting: ("Practice request sent", "It arrives in a few seconds.")
        case .notifications: ("Turn on notifications", "Requests then appear on your wrist. Approve or deny with a tap.")
        case .notificationsOff: ("Notifications are off", "Turn them on in the Apple Watch app on your iPhone, under Notifications.")
        case .settingUpNotifications: ("Setting up notifications", "Apple is connecting this Apple Watch for notifications. This usually takes a few seconds.")
        case .ready: ("Ready", "Requests appear here as notifications. Tap Approve or Deny.")
        }
    }
    static let continueButton = "Continue"
    static let add = "Add"
    static let tryPractice = "Try Practice"
    static let done = "Done"
    /// Not drawn: when Try Practice cannot reach the iPhone, or the iPhone cannot reach the Mac.
    static let practiceNotAsked = "Couldn’t ask for one. Your iPhone and Mac need to be nearby and awake."
    // The request card.
    static let deny = "Deny"
    static let approve = "Approve"
    static let denyAndExplain = "Deny and Explain"
    static let whatInstead = "What should it do instead?"
    static let unreadable = "Open Agent Keyring on your iPhone to see this request."
    static func project(_ name: String) -> String { "Project \(name)" }
    static func answered(approve: Bool, _ result: WatchDelegate.AnswerResult) -> String {
        switch (approve, result) {
        case (_, .alreadyAnswered): "Already answered"
        case (true, .sent): "Approved"
        case (false, .sent): "Denied"
        case (true, .failed): "Not approved. Try on your iPhone."
        case (false, .failed): "Not sent. Try on your iPhone."
        }
    }
    static let inUse = "In use"
    static let stop = "Stop"
    /// Not on the board: when Stop can't reach the iPhone.
    static let stopFailed = "Couldn’t stop it. Try on your iPhone."
    static func until(_ date: Date) -> String {
        "until " + date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "en_GB")))
    }
}

struct WatchHome: View {
    let model: WatchModel
    @State private var asking = false
    @State private var practiceFailed = false

    var body: some View {
        // Only "In use" while something is in use; otherwise the one line for where setup stands.
        // No title bar: on the board the screen is the line alone, clear of the clock.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let inUse = model.inUse.filter { $0.until > context.date }
            if model.setup == .ready && !inUse.isEmpty { WatchInUseList(items: inUse) } else { status }
        }
    }

    private var status: some View {
        let line = WatchCopy.line(model.setup)
        return ScrollView {
            VStack(spacing: 4) {
                if model.setup == .ready {
                    Circle().fill(Color(red: 0x23 / 255, green: 0xA4 / 255, blue: 0x55 / 255)).frame(width: 54, height: 54)
                        .overlay(Image(systemName: "checkmark").font(.system(size: 26, weight: .bold)).foregroundStyle(.white))
                        .padding(.bottom, 6)
                }
                Text(line.title).font(.system(size: 19, weight: .bold))
                Text(line.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                switch model.setup {
                case .notifications:
                    // watchOS's own question, only once the iPhone has added this Apple Watch.
                    action(WatchCopy.continueButton) {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                        await WatchLink.shared.refreshSetup()
                        await WatchLink.shared.sendHandOver()
                    }
                case .readyToAdd:
                    action(WatchCopy.add) { await WatchLink.shared.add() }
                case .addedOfferPractice:
                    action(WatchCopy.tryPractice) { practiceFailed = !(await WatchLink.shared.askForPractice()) }
                    action(WatchCopy.done) { await WatchLink.shared.practiceOfferDone() }
                    if practiceFailed { Text(WatchCopy.practiceNotAsked).font(.system(size: 13)).foregroundStyle(.secondary) }
                default:
                    EmptyView()
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 170)
        }
    }

    private func action(_ title: String, _ run: @escaping () async -> Void) -> some View {
        Button(title) {
            asking = true
            Task { await run(); asking = false }
        }
        .font(.system(size: 16, weight: .semibold))
        .buttonStyle(.plain)
        .frame(width: 170, height: 40)
        .background(Color.white.opacity(0.18), in: .capsule)
        .disabled(asking)
        .padding(.top, 8)
    }
}

/// Paper, "On iPhone and Apple Watch", Apple Watch: "In use", each with Stop.
struct WatchInUseList: View {
    let items: [WatchInUse]
    @State private var stopping: String?
    @State private var failed: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(WatchCopy.inUse).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.site).font(.system(size: 16, weight: .semibold))
                        Text(item.who).font(.system(size: 13)).foregroundStyle(.secondary)
                        Text(WatchCopy.until(item.until)).font(.system(size: 13)).foregroundStyle(.secondary)
                        if failed == item.id {
                            Text(WatchCopy.stopFailed).font(.system(size: 13)).padding(.top, 4)
                        }
                        Button(WatchCopy.stop) {
                            stopping = item.id
                            Task {
                                let stopped = await WatchLink.shared.stop(item.id)
                                failed = stopped ? nil : item.id
                                stopping = nil
                            }
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .disabled(stopping != nil)
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.12), in: .rect(cornerRadius: 20))
                }
            }
        }
    }
}

struct UncheckedHandler: @unchecked Sendable {
    let call: () -> Void
    init(_ call: @escaping () -> Void) { self.call = call }
}
