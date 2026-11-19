// Written by AI on 2026.11.19 by model Claude Opus 5.5.
//
// First run on the iPhone (Paper, "First run", row "On iPhone"): one screen
// at a time, ending in Done. The app still checks itself and reports to the
// relay; none of that is shown here.

#if os(iOS)
import SwiftUI
import UIKit

/// The screen for where first run stands. The practice request is a sheet over it.
struct PhoneFirstRunView: View {
    let stage: PhoneFirstRun
    let model: PhoneModel

    var body: some View {
        switch stage {
        case let .findingMac(macAsked, longWait):
            // After two minutes, Open Settings: iCloud Keychain is the one cause the app cannot see.
            PhoneWelcome(button: !macAsked && longWait ? PhoneCopy.openSettings : nil) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(macAsked ? PhoneCopy.approveOnMac : PhoneCopy.finishOnMac)
                        .font(.title3.weight(.semibold)).foregroundStyle(Phone.ink)
                    Text(macAsked ? PhoneCopy.approveOnMacDetail : PhoneCopy.finishOnMacDetail)
                        .font(.subheadline).foregroundStyle(Phone.ink2)
                    if !macAsked && longWait {
                        Text(PhoneCopy.finishOnMacLongWait)
                            .font(.subheadline).foregroundStyle(Phone.ink2).padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18).padding(.horizontal, 20)
                .background(Phone.fill, in: .rect(cornerRadius: 22))
            }
        case .notifications, .practice:
            // The practice request comes up over this screen as a sheet.
            PhoneStep(title: PhoneCopy.notificationsTitle, lead: PhoneCopy.notificationsLead,
                      button: stage == .notifications ? PhoneCopy.continueButton : nil) {
                await model.askAboutNotifications()
            }
        case .notificationsOff:
            PhoneStep(title: nil, lead: PhoneCopy.notificationsOff, button: PhoneCopy.openSettings) {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { await UIApplication.shared.open(url) }
            }
        case .practiceAgain:
            PhoneStep(title: PhoneCopy.practiceAgainTitle, lead: PhoneCopy.practiceAgainDetail, button: PhoneCopy.sendAnother) {
                await model.sendTestAgain()
            }
        case .done:
            PhoneStep(title: PhoneCopy.setUpTitle, lead: PhoneCopy.setUpLead, button: PhoneCopy.done, tick: true) {
                await model.finishFirstRun()
            }
        }
    }
}

/// The first screen: the icon, the name, what the app is for, and what it waits for.
private struct PhoneWelcome<Status: View>: View {
    var button: String? = nil
    @ViewBuilder let status: Status

    var body: some View {
        VStack(spacing: 0) {
            content.frame(maxHeight: .infinity, alignment: .top)
            if let button {
                Button(button) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(PillButtonStyle(fill: Phone.ink, text: Phone.surface))
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
            }
        }
        .background(Phone.surface)
    }

    private var content: some View {
        VStack(spacing: 40) {
            VStack(spacing: 18) {
                KeyholeIcon(size: 64)
                VStack(spacing: 8) {
                    Text(PhoneCopy.appName).font(.largeTitle.bold()).tracking(-0.75).foregroundStyle(Phone.ink)
                    Text(PhoneCopy.appLead).font(.body).foregroundStyle(Phone.ink2)
                }
                .multilineTextAlignment(.center)
            }
            status
        }
        .padding(.horizontal, 24)
        .padding(.top, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Phone.surface)
    }
}

/// One step: a title, a sentence, and one black button at the bottom.
private struct PhoneStep: View {
    let title: String?
    let lead: String
    let button: String?
    var tick = false
    let action: () async -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                if tick {
                    Circle().fill(Phone.approve).frame(width: 64, height: 64)
                        .overlay(Image(systemName: "checkmark").font(.system(size: 30, weight: .bold)).foregroundStyle(Phone.onAnswer))
                }
                VStack(spacing: 8) {
                    if let title {
                        Text(title).font(tick ? .largeTitle.bold() : .title.bold()).tracking(-0.6).foregroundStyle(Phone.ink)
                    }
                    Text(lead).font(title == nil ? .title3 : .body).foregroundStyle(title == nil ? Phone.ink : Phone.ink2)
                }
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 60)
            if let button {
                Button(button) { Task { await action() } }
                    .buttonStyle(PillButtonStyle(fill: Phone.ink, text: Phone.surface))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Phone.surface)
    }
}

/// A device's request to be added and a rule change from the Mac: the request
/// sheet with only Deny and Approve with Face ID.
struct PhoneSimpleRequestView: View {
    let model: PhoneModel
    let lead: String
    let title: String
    let detail: String?
    /// A rule change's lines under the title: the change in semibold, then what it would allow.
    var change: [String] = []
    var allows: String? = nil
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
                if !change.isEmpty || allows != nil {
                    VStack(spacing: 4) {
                        ForEach(Array(change.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.title3.weight(index == 0 ? .semibold : .regular)).foregroundStyle(Phone.ink)
                        }
                        if let allows { Text(allows).font(.title3).foregroundStyle(Phone.ink) }
                    }
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
