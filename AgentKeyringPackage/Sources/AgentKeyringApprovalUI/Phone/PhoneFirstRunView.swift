// Written by AI on 2026.11.19 by model Claude Opus 5.5.
//
// First run on the iPhone (Paper, "First run", iPhone row): one screen for
// each state of PhoneFirstRun. The app still checks itself and reports to the
// relay; none of that is shown here.

#if os(iOS)
import SwiftUI
import UIKit

/// One screen per state of first run; the practice request is a sheet over it.
struct PhoneFirstRunView: View {
    let stage: PhoneFirstRun
    let model: PhoneModel

    var body: some View {
        let relay = model.snapshot.relayName
        switch stage {
        case let .welcome(card, _):
            welcome(card)
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
        case .practiceWaiting, .practice:
            PhoneStep(title: PhoneCopy.practiceCheckTitle, lines: [PhoneCopy.practiceCheckDetail(relay)]) {
                PhoneWaitingLine(text: PhoneCopy.practiceWaiting)
            }
        case .practiceNotArrived:
            PhoneStep(title: PhoneCopy.practiceNotArrivedTitle, lines: [PhoneCopy.practiceNotArrivedDetail(relay)]) {
                PhoneButton(PhoneCopy.tryAgain) { await model.firstRun(.tryAgain) }
            }
        case .settingUpNotifications:
            PhoneStep(title: PhoneCopy.settingUpTitle, lines: [PhoneCopy.settingUpDetail]) { EmptyView() }
        case .ready, .finished:
            PhoneReady(watch: model.snapshot.watchPaired) { await model.firstRun(.done) }
        }
    }

    @ViewBuilder private func welcome(_ card: PhoneWelcomeCard) -> some View {
        switch card {
        case let .startOnMac(longWait):
            PhoneWelcome(title: PhoneCopy.startOnMac, lines: [PhoneCopy.startOnMacDetail] + (longWait ? [PhoneCopy.startOnMacLongWait] : [])) {
                PhoneButton(PhoneCopy.tryPractice, secondary: true) { await model.firstRun(.tryPractice) }
            }
        case let .addComputer(mac):
            PhoneWelcome(title: PhoneCopy.addComputer, lines: [PhoneCopy.addComputerDetail(mac)]) {
                PhoneButton(PhoneCopy.tryPractice, secondary: true) { await model.firstRun(.tryPractice) }
            }
        case let .approveOnMac(mac):
            PhoneWelcome(title: PhoneCopy.approveOn(mac), lines: [PhoneCopy.approveOnDetail(mac)]) {
                PhoneWaitingLine(text: PhoneCopy.waitingFor(mac))
            }
        case let .denied(mac):
            PhoneWelcome(title: PhoneCopy.didNotAdd(mac), lines: [PhoneCopy.didNotAddDetail(mac)]) {
                PhoneButton(PhoneCopy.askAgain) { await model.firstRun(.askAgain) }
            }
        }
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
                        Text(PhoneCopy.appName).font(.largeTitle.bold()).tracking(-0.75).foregroundStyle(Phone.ink)
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
    let title: String
    let lines: [String]
    @ViewBuilder let bottom: Bottom

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 22) {
                Image(systemName: "bell").font(.system(size: 32)).foregroundStyle(Phone.accent)
                    .frame(width: 72, height: 72).background(Phone.fill, in: .rect(cornerRadius: 18))
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

/// Ready: what to expect from now on, and Done.
private struct PhoneReady: View {
    let watch: Bool
    let done: () async -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 32) {
                VStack(spacing: 16) {
                    Circle().fill(Phone.approve).frame(width: 64, height: 64)
                        .overlay(Image(systemName: "checkmark").font(.system(size: 28, weight: .bold)).foregroundStyle(Phone.onAnswer))
                    Text(PhoneCopy.readyTitle).font(.title.bold()).tracking(-0.6).foregroundStyle(Phone.ink)
                }
                VStack(alignment: .leading, spacing: 22) {
                    row("bell", PhoneCopy.readyNotifications, PhoneCopy.readyNotificationsDetail)
                    row("clock", PhoneCopy.readyActivity, PhoneCopy.readyActivityDetail)
                    if watch { row("applewatch", PhoneCopy.readyWatch, PhoneCopy.readyWatchDetail) }
                }
            }
            .frame(maxHeight: .infinity)
            PhoneButton(PhoneCopy.done) { await done() }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 30)
        .background(Phone.surface)
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(Phone.accent).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(Phone.ink)
                Text(detail).font(.subheadline).foregroundStyle(Phone.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

/// Apple Watch's request to be added: the request sheet with only Deny and
/// Approve with Face ID.
struct PhoneSimpleRequestView: View {
    let model: PhoneModel
    let lead: String
    let title: String
    let detail: String?
    let footnote: String
    var dismissable = false
    /// Paper's request to add a device: Deny above the approve button, the same size.
    var stackedDeny = false
    let approve: () async -> Void
    let deny: () async -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                KeyholeIcon(size: 22)
                Text(PhoneCopy.appName).font(.subheadline.weight(.semibold)).foregroundStyle(Phone.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 18)
            VStack(spacing: 12) {
                VStack(spacing: 1) {
                    Text(lead).font(.subheadline).foregroundStyle(Phone.ink2)
                    Text(title).font(.largeTitle.bold()).tracking(-0.75).foregroundStyle(Phone.ink)
                    if let detail { Text(detail).font(.subheadline).foregroundStyle(Phone.ink2) }
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 40)
            VStack(spacing: 10) {
                if stackedDeny {
                    Button(PhoneCopy.deny) { Task { await deny() } }
                        .buttonStyle(PillButtonStyle(fill: Phone.fill, text: Phone.deny))
                } else {
                    Button(PhoneCopy.deny) { Task { await deny() } }
                        .buttonStyle(PillButtonStyle(fill: Phone.deny, height: 50, stretches: false))
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Button { Task { await approve() } } label: {
                    Label(PhoneCopy.approveWithFaceID, systemImage: "faceid").labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle(fill: Phone.approve))
                Text(footnote).font(.footnote).foregroundStyle(Phone.ink2).multilineTextAlignment(.center)
            }
            .disabled(model.answering != nil)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 44)
        .background(Phone.surface)
        .ignoresSafeArea(.container, edges: .bottom)
        .interactiveDismissDisabled(!dismissable)
    }
}
#endif
