// Written by AI on 2026.11.19 by model Claude Opus 5.5; rebuilt from the shared page parts on 2026.11.21.
//
// Adding this iPhone, and adding Apple Watch from it: one page per state of
// PhoneFirstRun and PhoneAddWatch, built only from AgentKeyringDesign's parts.
// Every word comes from PhoneCopy; the page owns every margin and colour.

#if os(iOS)
import AgentKeyringDesign
import SwiftUI
import UIKit

/// One page per state of first run; the practice request is a sheet over it.
struct PhoneFirstRunView: View {
    let stage: PhoneFirstRun
    let model: PhoneModel

    var body: some View {
        let mac = model.snapshot.macName
        switch stage {
        case .searching(let longWait):
            KeyringPage(title: PhoneCopy.continueFrom(nil), sentence: PhoneCopy.continueFromDetail, alignment: .centre, mascot: .waiting,
                        status: .waiting(PhoneCopy.lookingForMac),
                        secondary: longWait ? .link(PhoneCopy.havingTrouble) { send(.havingTrouble) } : nil) { trust }
        case .trouble:
            KeyringPage(title: PhoneCopy.troubleTitle, sentence: PhoneCopy.troubleBanner, mascot: .offline,
                        primary: .advance(PhoneCopy.tryAgain) { send(.tryAgain) }) {
                KeyringSteps(PhoneCopy.troubleSteps)
            }
        case .foundMac:
            KeyringPage(step: (1, 3), title: PhoneCopy.continueFrom(mac), sentence: PhoneCopy.continueFromDetail, alignment: .centre, mascot: .calm,
                        primary: .advance(PhoneCopy.connectTo(mac)) { send(.connect) },
                        secondary: .link(PhoneCopy.havingTrouble) { send(.havingTrouble) }) { trust }
        case .waitingForMac:
            KeyringPage(step: (1, 3), title: PhoneCopy.approveOn(mac), sentence: PhoneCopy.approveOnDetail(mac), alignment: .centre, mascot: .waiting,
                        status: .waiting(PhoneCopy.waitingFor(mac)), secondary: .plain(PhoneCopy.cancel) { send(.cancel) })
        case .deniedByMac:
            KeyringPage(step: (1, 3), title: PhoneCopy.notApprovedOn(mac), sentence: PhoneCopy.notApprovedDetail, alignment: .centre, mascot: .denied,
                        primary: .advance(PhoneCopy.askAgain) { send(.askAgain) }, secondary: .plain(PhoneCopy.cancel) { send(.cancel) })
        case .cantReachMac:
            KeyringPage(step: (1, 3), title: PhoneCopy.cantReach(mac), sentence: PhoneCopy.cantReachDetail(mac), alignment: .centre, mascot: .offline,
                        primary: .advance(PhoneCopy.tryAgain) { send(.tryAgain) }, secondary: .plain(PhoneCopy.cancel) { send(.cancel) })
        case .expired:
            KeyringPage(step: (1, 3), title: PhoneCopy.joinExpiredTitle, sentence: PhoneCopy.joinExpiredDetail(mac), alignment: .centre, mascot: .offline,
                        primary: .advance(PhoneCopy.askAgain) { send(.askAgain) }, secondary: .plain(PhoneCopy.cancel) { send(.cancel) })
        case .receivingPasswords:
            KeyringPage(step: (1, 3), title: PhoneCopy.receivingTitle, alignment: .centre, mascot: .waiting,
                        status: .waiting(PhoneCopy.receivingDetail(model.snapshot.filling)))
        case .notifications, .askingNotifications, .notificationsOff:
            notifications
        case .practiceOffer:
            practicePage(primary: .advance(PhoneCopy.sendPractice) { sendPractice() }, secondary: skip) {
                KeyringHint(symbol: "bell.badge", title: PhoneCopy.practicePreviewTitle, PhoneCopy.practicePreview)
                KeyringHint(symbol: "moon.fill", PhoneCopy.practiceNote, tone: .plain)
            }
        case .practiceWaiting, .practice:
            practicePage(status: .waiting(PhoneCopy.practiceWaiting)) { EmptyView() }
        case .settingUpNotifications:
            practicePage(status: .takingLong(PhoneCopy.practiceSettingUp), secondary: skip) { EmptyView() }
        case .practiceNotArrived:
            practicePage(status: .takingLong(PhoneCopy.practiceNotArrived),
                         primary: .advance(PhoneCopy.answerItHere) { send(.practiceTapped) },
                         secondary: .plain(PhoneCopy.tryAgain) { sendPractice() }, aside: skip) {
                KeyringHint(symbol: "moon.fill", PhoneCopy.notificationsFocus, tone: .focus)
            }
        case .practiceMacUnreachable:
            practicePage(status: .problem(PhoneCopy.practiceMacAsleep(mac)),
                         primary: .advance(PhoneCopy.tryAgain) { sendPractice() }, secondary: skip) { EmptyView() }
        case let .practiceResult(outcome):
            practicePage(primary: .advance(PhoneCopy.continueButton) { continueAfterPractice() },
                         secondary: .plain(PhoneCopy.sendAnother) { sendPractice() }) {
                KeyringConfirmation(PhoneCopy.practiceResult(outcome), tone: outcome == .approved ? .approved : .denied)
            }
        case let .readyOfferWatch(watchToAdd):
            KeyringPage(title: PhoneCopy.readyTitle, sentence: PhoneCopy.readyDetail, alignment: .centre, mascot: .approved,
                        primary: watchToAdd ? .advance(PhoneCopy.addAppleWatch) { send(.addAppleWatch) } : .advance(PhoneCopy.done) { send(.done) },
                        secondary: watchToAdd ? .plain(PhoneCopy.done) { send(.done) } : nil) {
                if watchToAdd { KeyringHint(symbol: "applewatch", title: PhoneCopy.addWatchOfferTitle, PhoneCopy.addWatchOfferDetail) }
            }
        case .addWatch:
            PhoneAddWatchView(flow: model.snapshot.addWatch, model: model)
        case .finished:
            EmptyView()
        }
    }

    private var trust: some View {
        KeyringHint(symbol: "lock.fill", title: PhoneCopy.trustTitle, PhoneCopy.trustDetail)
    }

    /// The checklist ticks only from what iOS lets the app read.
    private var notifications: some View {
        let facts = model.snapshot.notificationFacts
        let asked = facts.allowed || stage == .notificationsOff
        let primary: KeyringAction = stage == .notificationsOff ? .advance(PhoneCopy.openSettings) { openNotificationSettings() }
            : !asked ? .advance(PhoneCopy.turnOnNotifications) { Task { await model.askAboutNotifications() } }
            : .advance(PhoneCopy.continueButton) { send(.notificationsDone) }
        let allSet = facts.allowed && facts.banners && facts.lockScreen && facts.timeSensitive && !facts.inScheduledSummary
        let secondary: KeyringAction? = stage == .notificationsOff ? .link(PhoneCopy.continueWithout) { send(.continueWithoutNotifications) }
            : asked && !allSet ? .plain(PhoneCopy.openSettings) { openNotificationSettings() } : nil
        return KeyringPage(step: (2, 3), title: PhoneCopy.notificationsTitle, sentence: PhoneCopy.notificationsLead,
                           status: stage == .notificationsOff ? .problem(PhoneCopy.notificationsOff) : nil,
                           primary: primary, secondary: secondary) {
            KeyringRowGroup {
                check(PhoneCopy.checkAllowed, facts.allowed, fix: asked ? PhoneCopy.checkInSettings : PhoneCopy.checkTurnOnFirst)
                check(PhoneCopy.checkBanners, facts.banners && facts.lockScreen, fix: PhoneCopy.checkInSettings)
                check(PhoneCopy.checkTimeSensitive, facts.timeSensitive, fix: PhoneCopy.checkInSettings)
                check(PhoneCopy.checkNotScheduled, facts.allowed && !facts.inScheduledSummary, fix: PhoneCopy.checkScheduledInSettings)
            }
            KeyringHint(symbol: "moon.fill", PhoneCopy.notificationsFocus, tone: .focus)
        }
    }

    /// A ticked row, or an unticked one with what to do. Before iOS has asked, only the first row says what.
    private func check(_ name: String, _ on: Bool, fix: String) -> some View {
        let asked = model.snapshot.notificationFacts.allowed || stage == .notificationsOff
        return KeyringDeviceRow(symbol: on ? "checkmark" : "circle", name: name,
                                detail: on || (!asked && name != PhoneCopy.checkAllowed) ? nil : fix, tone: on ? .approved : .plain)
    }

    private func practicePage(status: KeyringStatus? = nil, primary: KeyringAction? = nil, secondary: KeyringAction? = nil,
                              aside: KeyringAction? = nil, @ViewBuilder content: () -> some View) -> some View {
        KeyringPage(step: (3, 3), title: PhoneCopy.practiceTitle, sentence: PhoneCopy.practiceLead, status: status,
                    primary: primary, secondary: secondary, aside: aside, content: content)
    }

    private var skip: KeyringAction { .link(PhoneCopy.skipForNow) { continueAfterPractice() } }

    private func send(_ event: PhoneFirstRun.Event) { Task { await model.firstRun(event) } }
    private func sendPractice() { send(.sendPractice(id: PhoneFirstRun.newPracticeID())) }
    private func continueAfterPractice() { send(.continueAfterPractice(watchToAdd: model.snapshot.watch.toAdd)) }

    private func openNotificationSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// Adding Apple Watch, one page per state; from first run or from Devices.
struct PhoneAddWatchView: View {
    let flow: PhoneAddWatch?
    let model: PhoneModel

    var body: some View {
        switch flow {
        case .notPaired:
            KeyringPage(title: PhoneCopy.notPairedTitle, alignment: .centre, mascot: .curious, primary: .plain(PhoneCopy.close) { tap(.cancel) })
        case .watchAppMissing:
            KeyringPage(title: PhoneCopy.installOnWatchTitle, sentence: PhoneCopy.installOnWatchDetail,
                        primary: .advance(PhoneCopy.checkAgain) { tap(.checkAgain) }, secondary: .link(PhoneCopy.doThisLater) { tap(.cancel) }) {
                KeyringSteps(PhoneCopy.installOnWatchSteps)
            }
        case .faceIDFirst:
            KeyringPage(step: (1, 2), title: PhoneCopy.addWatchTitle, sentence: PhoneCopy.addWatchDetail,
                        primary: .advance(PhoneCopy.continueWithFaceID) { tap(.continueWithFaceID) },
                        secondary: .link(PhoneCopy.cancel) { tap(.cancel) }) {
                KeyringSteps(PhoneCopy.addWatchSteps)
            }
        case let .waitingForWatch(until):
            KeyringPage(step: (2, 2), title: PhoneCopy.tapAddOnWatch, sentence: PhoneCopy.tapAddOnWatchDetail, secondary: cancel) {
                KeyringConfirmation(PhoneCopy.confirmedUntil(until))
                KeyringHint(symbol: "exclamationmark.circle.fill", title: PhoneCopy.watchNotShowingTitle, PhoneCopy.watchNotShowing, tone: .stalled)
            }
        case .faceIDExpired:
            KeyringPage(step: (1, 2), title: PhoneCopy.addWatchTitle, status: .takingLong(PhoneCopy.faceIDExpired),
                        primary: .advance(PhoneCopy.continueWithFaceID) { tap(.continueWithFaceID) }, secondary: cancel)
        case .watchNeedsPasscode:
            KeyringPage(step: (2, 2), title: PhoneCopy.addWatchTitle, status: .problem(PhoneCopy.watchNeedsPasscode),
                        primary: .advance(PhoneCopy.tryAgain) { tap(.tryAgain) }, secondary: cancel)
        case let .encrypting(done, total):
            KeyringPage(step: (2, 2), title: PhoneCopy.addWatchTitle, status: .waiting(PhoneCopy.encryptingForWatch(done, total)))
        case let .copiesFailed(reason):
            KeyringPage(step: (2, 2), title: PhoneCopy.addWatchTitle, status: .problem(PhoneCopy.watchCopiesFailed(reason)),
                        primary: .advance(PhoneCopy.tryAgain) { tap(.tryAgain) }, secondary: cancel)
        case .added:
            KeyringPage(title: PhoneCopy.watchAdded, sentence: PhoneCopy.watchAddedDetail, alignment: .centre, mascot: .approved,
                        primary: .advance(PhoneCopy.done) { tap(.done) })
        case .closed, nil:
            EmptyView()
        }
    }

    private var cancel: KeyringAction { .plain(PhoneCopy.cancel) { tap(.cancel) } }
    private func tap(_ tap: PhoneAddWatchTap) { Task { await model.addWatch(tap) } }
}
#endif
