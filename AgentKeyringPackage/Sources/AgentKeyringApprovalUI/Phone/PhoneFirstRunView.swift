// Written by AI on 2026.11.19 by model Claude Opus 5.5.
//
// First run on the iPhone (Paper, "First run", iPhone row): one screen for
// each state of PhoneFirstRun. The app still checks itself and reports to the
// relay; none of that is shown here.

#if os(iOS)
import SwiftUI
import UIKit

/// One screen per state of first run; the practice request is a sheet over it. The pages themselves wait
/// for the drawings: these show each state plainly with today's parts.
struct PhoneFirstRunView: View {
    let stage: PhoneFirstRun
    let model: PhoneModel

    var body: some View {
        let mac = model.snapshot.macName
        switch stage {
        case .searching(let longWait):
            PhoneWelcome(title: PhoneCopy.lookingForMac, lines: [PhoneCopy.lookingForMacDetail]) {
                PhoneWaitingLine(text: PhoneCopy.lookingForMac)
                if longWait { trouble }
            }
        case .trouble:
            PhoneWelcome(title: PhoneCopy.troubleTitle, lines: [PhoneCopy.troubleBanner] + PhoneCopy.troubleSteps) {
                PhoneButton(PhoneCopy.tryAgain) { await model.firstRun(.tryAgain) }
            }
        case .foundMac:
            PhoneWelcome(title: PhoneCopy.continueFrom(mac), lines: [PhoneCopy.continueFromDetail, PhoneCopy.welcomeSecureDetail]) {
                PhoneButton(PhoneCopy.connectTo(mac)) { await model.firstRun(.connect) }
                trouble
            }
        case .waitingForMac:
            PhoneWelcome(title: PhoneCopy.approveOn(mac), lines: [PhoneCopy.approveOnDetail(mac)]) {
                PhoneWaitingLine(text: PhoneCopy.waitingFor(mac))
                PhoneButton(PhoneCopy.cancel, secondary: true) { await model.firstRun(.cancel) }
            }
        case .deniedByMac:
            PhoneWelcome(title: PhoneCopy.didNotAdd(mac), lines: [PhoneCopy.didNotAddDetail(mac)]) {
                PhoneButton(PhoneCopy.askAgain) { await model.firstRun(.askAgain) }
                PhoneButton(PhoneCopy.cancel, secondary: true) { await model.firstRun(.cancel) }
            }
        case .cantReachMac:
            PhoneWelcome(title: PhoneCopy.cantReach(mac), lines: [PhoneCopy.cantReachDetail(mac)]) {
                PhoneButton(PhoneCopy.tryAgain) { await model.firstRun(.tryAgain) }
                PhoneButton(PhoneCopy.cancel, secondary: true) { await model.firstRun(.cancel) }
            }
        case .expired:
            PhoneWelcome(title: PhoneCopy.joinExpiredTitle, lines: [PhoneCopy.joinExpiredDetail(mac)]) {
                PhoneButton(PhoneCopy.askAgain) { await model.firstRun(.askAgain) }
                PhoneButton(PhoneCopy.cancel, secondary: true) { await model.firstRun(.cancel) }
            }
        case .receivingPasswords:
            PhoneStep(title: PhoneCopy.receivingPasswords, lines: [PhoneCopy.receivingDetail(model.snapshot.filling)], icon: "lock") {
                PhoneWaitingLine(text: PhoneCopy.receivingPasswords)
            }
        case .notifications, .askingNotifications:
            PhoneStep(title: PhoneCopy.notificationsTitle, lines: [PhoneCopy.notificationsLead, PhoneCopy.notificationsFocus]) {
                PhoneButton(PhoneCopy.continueButton) { await model.askAboutNotifications() }
            }
        case .notificationsOff:
            PhoneStep(title: PhoneCopy.notificationsOffTitle, lines: [PhoneCopy.notificationsOff]) {
                PhoneButton(PhoneCopy.openSettings) {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { await UIApplication.shared.open(url) }
                }
                PhoneButton(PhoneCopy.continueWithout, secondary: true) { await model.firstRun(.continueWithoutNotifications) }
            }
        case .practiceOffer:
            PhoneStep(title: PhoneCopy.practiceOfferTitle, lines: [PhoneCopy.practiceOfferDetail]) {
                PhoneButton(PhoneCopy.sendPractice) { await model.firstRun(.sendPractice(id: PhoneFirstRun.newPracticeID())) }
                PhoneButton(PhoneCopy.skipForNow, secondary: true) { await model.firstRun(.continueAfterPractice(watchToAdd: model.snapshot.watch.toAdd)) }
            }
        case .practiceWaiting, .practice:
            PhoneStep(title: PhoneCopy.practiceCheckTitle, lines: [PhoneCopy.practiceCheckDetail(mac)]) {
                PhoneWaitingLine(text: PhoneCopy.practiceWaiting)
            }
        case .practiceNotArrived:
            PhoneStep(title: PhoneCopy.practiceNotArrivedTitle, lines: [PhoneCopy.practiceNotArrivedDetail(mac)]) {
                PhoneButton(PhoneCopy.tryAgain) { await model.firstRun(.sendPractice(id: PhoneFirstRun.newPracticeID())) }
                PhoneButton(PhoneCopy.skipForNow, secondary: true) { await model.firstRun(.continueAfterPractice(watchToAdd: model.snapshot.watch.toAdd)) }
            }
        case .practiceMacUnreachable:
            PhoneStep(title: PhoneCopy.practiceMacUnreachableTitle(mac), lines: [PhoneCopy.practiceMacUnreachableDetail(mac)]) {
                PhoneButton(PhoneCopy.tryAgain) { await model.firstRun(.sendPractice(id: PhoneFirstRun.newPracticeID())) }
                PhoneButton(PhoneCopy.skipForNow, secondary: true) { await model.firstRun(.continueAfterPractice(watchToAdd: model.snapshot.watch.toAdd)) }
            }
        case .settingUpNotifications:
            PhoneStep(title: PhoneCopy.settingUpTitle, lines: [PhoneCopy.settingUpDetail]) {
                PhoneButton(PhoneCopy.skipForNow, secondary: true) { await model.firstRun(.continueAfterPractice(watchToAdd: model.snapshot.watch.toAdd)) }
            }
        case let .practiceResult(outcome):
            PhoneStep(title: PhoneCopy.practiceResultTitle(outcome), lines: [PhoneCopy.practiceResultDetail(outcome)],
                      mark: outcome == .approved ? .approved : outcome == .denied ? .denied : nil) {
                PhoneButton(PhoneCopy.sendAnother, secondary: true) { await model.firstRun(.sendPractice(id: PhoneFirstRun.newPracticeID())) }
                PhoneButton(PhoneCopy.continueButton) { await model.firstRun(.continueAfterPractice(watchToAdd: model.snapshot.watch.toAdd)) }
            }
        case let .readyOfferWatch(watchToAdd):
            PhoneStep(title: watchToAdd ? PhoneCopy.addAppleWatchQuestion : PhoneCopy.homeReady, lines: [], icon: "applewatch") {
                if watchToAdd { PhoneButton(PhoneCopy.addAppleWatch) { await model.firstRun(.addAppleWatch) } }
                PhoneButton(PhoneCopy.done, secondary: watchToAdd) { await model.firstRun(.done) }
            }
        case .addWatch:
            PhoneAddWatchView(flow: model.snapshot.addWatch, model: model)
        case .finished:
            EmptyView()
        }
    }

    private var trouble: some View {
        Button(PhoneCopy.havingTrouble) { Task { await model.firstRun(.havingTrouble) } }
            .font(.subheadline.weight(.semibold)).foregroundStyle(Phone.accent).frame(height: 36)
    }
}

/// Adding Apple Watch, one screen per state; from first run or from Devices.
struct PhoneAddWatchView: View {
    let flow: PhoneAddWatch?
    let model: PhoneModel

    var body: some View {
        switch flow {
        case .notPaired:
            PhoneStep(title: PhoneCopy.notPairedTitle, lines: [], icon: "applewatch") { cancel(PhoneCopy.close) }
        case .watchAppMissing:
            PhoneStep(title: PhoneCopy.installOnWatchTitle, lines: [PhoneCopy.installOnWatchDetail], icon: "applewatch") {
                PhoneButton(PhoneCopy.checkAgain) { await model.addWatch(.checkAgain) }
                cancel(PhoneCopy.cancel)
            }
        case .faceIDFirst:
            PhoneStep(title: PhoneCopy.addWatchTitle, lines: [PhoneCopy.addWatchFaceIDDetail], icon: "applewatch") {
                PhoneButton(PhoneCopy.continueWithFaceID) { await model.addWatch(.continueWithFaceID) }
                cancel(PhoneCopy.cancel)
            }
        case let .waitingForWatch(until):
            PhoneStep(title: PhoneCopy.tapAddOnWatch, lines: [PhoneCopy.confirmedUntil(until), PhoneCopy.tapAddOnWatchDetail], icon: "applewatch") {
                PhoneWaitingLine(text: PhoneCopy.tapAddOnWatch)
                cancel(PhoneCopy.cancel)
            }
        case .faceIDExpired:
            PhoneStep(title: PhoneCopy.faceIDExpiredTitle, lines: [PhoneCopy.faceIDExpiredDetail], icon: "faceid") {
                PhoneButton(PhoneCopy.continueWithFaceID) { await model.addWatch(.continueWithFaceID) }
                cancel(PhoneCopy.cancel)
            }
        case .watchNeedsPasscode:
            PhoneStep(title: PhoneCopy.watchNeedsPasscodeTitle, lines: [PhoneCopy.watchNeedsPasscodeDetail], icon: "applewatch") {
                PhoneButton(PhoneCopy.tryAgain) { await model.addWatch(.tryAgain) }
                cancel(PhoneCopy.cancel)
            }
        case let .encrypting(done, total):
            PhoneStep(title: PhoneCopy.encryptingForWatch(done, total), lines: [], icon: "lock") { EmptyView() }
        case .copiesFailed:
            PhoneStep(title: PhoneCopy.watchCopiesFailed, lines: [], icon: "applewatch") {
                PhoneButton(PhoneCopy.tryAgain) { await model.addWatch(.tryAgain) }
                cancel(PhoneCopy.cancel)
            }
        case .added:
            PhoneStep(title: PhoneCopy.watchAdded, lines: [], mark: .approved) {
                PhoneButton(PhoneCopy.done) { await model.addWatch(.done) }
            }
        case .closed, nil:
            EmptyView()
        }
    }

    private func cancel(_ title: String) -> some View {
        PhoneButton(title, secondary: true) { await model.addWatch(.cancel) }
    }
}

/// The first screen: the icon, the name, what the app is for, and a card for where setup stands.
private struct PhoneWelcome<Bottom: View>: View {
    let title: String
    let lines: [String]
    @ViewBuilder let bottom: Bottom

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 32) {
                VStack(spacing: 16) {
                    KeyholeIcon(size: 64)
                    VStack(spacing: 8) {
                        Text(PhoneCopy.welcomeTitle).font(.largeTitle.bold()).tracking(-0.75).foregroundStyle(Phone.ink)
                        Text(PhoneCopy.appLead).font(.body).foregroundStyle(Phone.ink2)
                    }
                    .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.title3.weight(.semibold)).foregroundStyle(Phone.ink)
                    ForEach(lines, id: \.self) { Text($0).font(.subheadline).foregroundStyle(Phone.ink2) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18).padding(.horizontal, 20)
                .background(Phone.fill, in: .rect(cornerRadius: 22))
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 40)
            VStack(spacing: 10) { bottom }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 30)
        .background(Phone.surface)
    }
}

/// One step: the bell in its tile, a title, its sentences, and the buttons at the bottom.
private struct PhoneStep<Bottom: View>: View {
    enum Mark { case approved, denied }
    let title: String
    let lines: [String]
    var icon = "bell"
    /// In place of the icon: a green tick or a red cross, for the practice's result.
    var mark: Mark? = nil
    @ViewBuilder let bottom: Bottom

    init(title: String, lines: [String], icon: String = "bell", mark: Mark? = nil, @ViewBuilder bottom: () -> Bottom) {
        self.title = title; self.lines = lines; self.icon = icon; self.mark = mark; self.bottom = bottom()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 22) {
                if let mark {
                    Circle().fill(mark == .approved ? Phone.approve : Phone.deny).frame(width: 64, height: 64)
                        .overlay(Image(systemName: mark == .approved ? "checkmark" : "xmark").font(.system(size: 28, weight: .bold)).foregroundStyle(Phone.onAnswer))
                } else {
                    Image(systemName: icon).font(.system(size: 32)).foregroundStyle(Phone.accent)
                        .frame(width: 72, height: 72).background(Phone.fill, in: .rect(cornerRadius: 18))
                }
                VStack(spacing: 14) {
                    Text(title).font(.title.bold()).tracking(-0.6).foregroundStyle(Phone.ink)
                    ForEach(lines, id: \.self) { Text($0).font(.body).foregroundStyle(Phone.ink2) }
                }
                .multilineTextAlignment(.center)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 100)
            VStack(spacing: 10) { bottom }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 30)
        .background(Phone.surface)
    }
}

/// A pill at the bottom: black, or grey for the second choice.
private struct PhoneButton: View {
    let title: String
    var secondary = false
    let action: () async -> Void

    init(_ title: String, secondary: Bool = false, action: @escaping () async -> Void) {
        self.title = title; self.secondary = secondary; self.action = action
    }

    var body: some View {
        Button(title) { Task { await action() } }
            .buttonStyle(PillButtonStyle(fill: secondary ? Phone.fill : Phone.ink, text: secondary ? Phone.ink : Phone.surface))
    }
}

/// A spinner and what the screen waits for, where a button would be.
private struct PhoneWaitingLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).font(.subheadline).foregroundStyle(Phone.ink2)
        }
        .frame(height: 50)
    }
}

#endif
