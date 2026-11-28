// Written by AI on 2026.11.19 by model Claude Opus 5.5; rebuilt from the shared page parts on 2026.11.21.
//
// Adding this iPhone, and adding Apple Watch from it: one page per state of
// PhoneFirstRun and PhoneAddWatch, built only from AgentKeyringDesign's parts.
// Every word comes from PhoneCopy; the page owns every margin and colour.

#if os(iOS)
import AgentKeyringApprovalCore
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
        case .searching:
            KeyringPage(alignment: .centre, mascot: .waiting, status: .waiting(PhoneCopy.lookingForMac))
        case .welcome:
            KeyringPage(title: PhoneCopy.welcomeTitle, sentence: PhoneCopy.welcomeDetail, alignment: .centre, mascot: .calm,
                        primary: .advance(PhoneCopy.setUpHere) { setUpHere() },
                        secondary: .link(PhoneCopy.alreadySetUpOnMac) { send(.havingTrouble) })
        case .trouble:
            KeyringPage(title: PhoneCopy.troubleTitle, sentence: PhoneCopy.troubleLead, mascot: .curious,
                        primary: .advance(PhoneCopy.tryAgain) { send(.tryAgain) },
                        secondary: .plain(PhoneCopy.back) { send(.cancel) }) {
                KeyringSteps(PhoneCopy.troubleSteps)
            }
        case .foundMac:
            KeyringPage(step: (1, 3), title: PhoneCopy.continueFrom(mac), sentence: PhoneCopy.continueFromDetail(mac), alignment: .centre, mascot: .calm,
                        primary: .advance(PhoneCopy.connectTo(mac)) { send(.connect) },
                        secondary: .plain(PhoneCopy.setUpHere) { setUpHere() }) { trust }
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
        case .importPasswords:
            PhoneCopyPasswordsPage(model: model, inFirstRun: true)
        case .receivingPasswords:
            KeyringPage(step: (1, 3), title: PhoneCopy.receivingTitle, alignment: .centre, mascot: .waiting) {
                PhoneProgressCard(
                    symbol: "lock.shield",
                    title: PhoneCopy.receivingDetail(model.snapshot.filling),
                    done: model.snapshot.filling?.copied,
                    total: model.snapshot.filling?.of,
                    footnote: PhoneCopy.otherDevicesGetCopies
                )
            }
        case .notifications, .askingNotifications, .notificationsOff:
            notifications
        case .practiceOffer:
            practicePage(primary: .advance(PhoneCopy.sendPractice) { sendPractice() }, secondary: skip) {
                KeyringHint(symbol: "moon.fill", PhoneCopy.practiceNote, tone: .plain)
            }
        case let .practiceWaiting(id, arrived):
            if arrived && hasActivePractice(id) {
                practiceArrivedPage
            } else {
                practicePage(status: .waiting(PhoneCopy.practiceWaiting), aside: skip) { EmptyView() }
            }
        case .practice:
            practiceArrivedPage
        case .settingUpNotifications:
            practicePage(status: .takingLong(PhoneCopy.practiceSettingUp),
                         primary: .advance(PhoneCopy.tryAgain) { sendPractice() }, secondary: skip) { EmptyView() }
        case let .practiceNotArrived(id):
            let canAnswerHere = hasActivePractice(id)
            practicePage(status: .takingLong(PhoneCopy.practiceNotArrived),
                         primary: canAnswerHere ? .advance(PhoneCopy.answerItHere) { send(.practiceTapped) } : .advance(PhoneCopy.tryAgain) { sendPractice() },
                         secondary: canAnswerHere ? .plain(PhoneCopy.tryAgain) { sendPractice() } : skip,
                         aside: canAnswerHere ? skip : nil) {
                KeyringHint(symbol: "moon.fill", PhoneCopy.notificationsFocus, tone: .focus)
            }
        case .practiceMacUnreachable:
            practicePage(status: .problem(PhoneCopy.practiceNotSent),
                         primary: .advance(PhoneCopy.tryAgain) { sendPractice() }, secondary: skip) { EmptyView() }
        case let .practiceResult(outcome):
            practicePage(primary: .advance(PhoneCopy.continueButton) { continueAfterPractice() },
                         secondary: .plain(PhoneCopy.sendAnother) { sendPractice() }) {
                KeyringConfirmation(PhoneCopy.practiceResult(outcome, reply: model.snapshot.practiceDeniedReply),
                                    tone: outcome == .approved ? .approved : .denied)
            }
        case let .readyOfferWatch(watchToAdd):
            // With no computer or Mac yet, agents have nowhere to ask from: Ready offers to add one.
            let addComputer: KeyringAction? = model.snapshot.hasComputer ? nil : .link(PhoneCopy.addAComputer) { send(.addAComputer) }
            KeyringPage(title: PhoneCopy.readyTitle, sentence: PhoneCopy.readyDetail, alignment: .centre, mascot: .approved,
                        primary: watchToAdd ? .advance(PhoneCopy.addAppleWatch) { send(.addAppleWatch) } : .advance(PhoneCopy.done) { send(.done) },
                        secondary: watchToAdd ? .plain(PhoneCopy.done) { send(.done) } : nil, aside: addComputer) {
                if watchToAdd { KeyringHint(symbol: "applewatch", title: PhoneCopy.addWatchOfferTitle, PhoneCopy.addWatchOfferDetail) }
            }
        case .addWatch:
            PhoneAddWatchView(flow: model.snapshot.addWatch, model: model)
        case .addComputer:
            NavigationStack {
                PhoneAddComputerPage(model: model)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(PhoneCopy.done) { send(.done) } } }
            }
        case .finished:
            EmptyView()
        }
    }

    private var trust: some View {
        KeyringHint(symbol: "lock.fill", title: PhoneCopy.trustTitle, PhoneCopy.trustDetail(model.snapshot.macName))
    }

    /// The checklist ticks only from what iOS lets the app read.
    private var notifications: some View {
        let facts = model.snapshot.notificationFacts
        let asked = facts.allowed || stage == .notificationsOff
        let primary: KeyringAction = stage == .notificationsOff ? .advance(PhoneCopy.openSettings) { openNotificationSettings() }
            : !asked ? .advance(PhoneCopy.turnOnNotifications, isEnabled: !model.isAskingNotifications) { Task { await model.askAboutNotifications() } }
            : .advance(PhoneCopy.continueButton) { send(.notificationsDone) }
        let allSet = facts.allowed && facts.banners && facts.lockScreen && facts.timeSensitive && !facts.inScheduledSummary
        let secondary: KeyringAction? = stage == .notificationsOff ? .link(PhoneCopy.continueWithout) { send(.continueWithoutNotifications) }
            : !asked ? .link(PhoneCopy.skipForNow) { send(.continueWithoutNotifications) }
            : !allSet ? .plain(PhoneCopy.openSettings) { openNotificationSettings() } : nil
        let allowedTitle = !asked ? PhoneCopy.checkNotYetAllowed : (facts.allowed ? PhoneCopy.checkAllowed : PhoneCopy.checkTurnedOff)
        return KeyringPage(step: (2, 3), title: PhoneCopy.notificationsTitle, sentence: PhoneCopy.notificationsLead,
                           status: stage == .notificationsOff ? .problem(PhoneCopy.notificationsOff) : nil,
                           primary: primary, secondary: secondary) {
            KeyringRowGroup {
                check(allowedTitle, facts.allowed, asked: asked, isPrimaryRow: true, fix: asked ? PhoneCopy.checkInSettings : PhoneCopy.checkTurnOnFirst)
                check(PhoneCopy.checkBanners, facts.banners && facts.lockScreen, asked: asked, fix: PhoneCopy.checkInSettings)
                check(PhoneCopy.checkTimeSensitive, facts.timeSensitive, asked: asked, fix: PhoneCopy.checkInSettings)
                check(PhoneCopy.checkNotScheduled, facts.allowed && !facts.inScheduledSummary, asked: asked, fix: PhoneCopy.checkScheduledInSettings)
            }
            KeyringHint(symbol: "moon.fill", PhoneCopy.notificationsFocus, tone: .focus)
        }
    }

    /// A ticked row once on, a neutral pending circle before iOS has asked, or an orange mark with what to do.
    private func check(_ name: String, _ on: Bool, asked: Bool, isPrimaryRow: Bool = false, fix: String) -> some View {
        let status: KeyringCheckStatus = on ? .done : (asked ? .needsAttention : .pending)
        let detail: String? = on ? nil : ((!asked && !isPrimaryRow) ? nil : fix)
        return KeyringCheckRow(name, status: status, toDo: detail)
    }

    private func practicePage(status: KeyringStatus? = nil, primary: KeyringAction? = nil, secondary: KeyringAction? = nil,
                              aside: KeyringAction? = nil, @ViewBuilder content: () -> some View) -> some View {
        KeyringPage(step: (3, 3), title: PhoneCopy.practiceTitle, sentence: PhoneCopy.practiceLead, status: status,
                    primary: primary, secondary: secondary, aside: aside, content: content)
    }

    /// Calm arrived state: points up to the real iOS notification banner without a competing primary button.
    private var practiceArrivedPage: some View {
        practicePage(primary: .plain(PhoneCopy.sendAnother) { sendPractice() },
                     secondary: .link(PhoneCopy.answerItHere) { send(.practiceTapped) },
                     aside: skip) {
            KeyringHint(symbol: "bell.badge", PhoneCopy.practiceArrived)
        }
    }

    private var skip: KeyringAction { .link(PhoneCopy.skipForNow) { continueAfterPractice() } }
    private func hasActivePractice(_ id: String) -> Bool {
        guard let state = model.accessRequest(id: id)?.state else { return false }
        switch state {
        case let .waitingForYou(until): return until > .now
        case .sendingAnswer: return true
        default: return false
        }
    }

    private func send(_ event: PhoneFirstRunEvent) { Task { await model.sendFirstRunEvent(event) } }
    private func setUpHere() { Task { await model.setUpHere() } }
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
                        primary: .advance(PhoneCopy.continueWithFaceID, isEnabled: !model.isAuthorizingWatch) { tap(.continueWithFaceID) },
                        secondary: .link(PhoneCopy.cancel) { tap(.cancel) }) {
                KeyringSteps(PhoneCopy.addWatchSteps)
            }
        case let .waitingForWatch(until):
            KeyringPage(step: (2, 2), title: PhoneCopy.tapAddOnWatch, sentence: PhoneCopy.tapAddOnWatchDetail, secondary: cancel) {
                KeyringConfirmation(PhoneCopy.confirmedUntil(until))
                KeyringSteps(PhoneCopy.tapAddOnWatchSteps)
                KeyringHint(symbol: "applewatch", title: PhoneCopy.watchNotShowingTitle, PhoneCopy.watchNotShowing, tone: .plain)
            }
        case .faceIDExpired:
            KeyringPage(step: (1, 2), title: PhoneCopy.addWatchTitle, status: .takingLong(PhoneCopy.faceIDExpired),
                        primary: .advance(PhoneCopy.continueWithFaceID, isEnabled: !model.isAuthorizingWatch) { tap(.continueWithFaceID) }, secondary: cancel)
        case .watchNeedsPasscode:
            KeyringPage(step: (2, 2), title: PhoneCopy.addWatchTitle, status: .problem(PhoneCopy.watchNeedsPasscode),
                        primary: .advance(PhoneCopy.tryAgain) { tap(.tryAgain) }, secondary: cancel)
        case let .encrypting(done, total):
            KeyringPage(step: (2, 2), title: PhoneCopy.addWatchTitle, alignment: .centre, mascot: .waiting) {
                PhoneProgressCard(
                    symbol: "applewatch",
                    title: PhoneCopy.encryptingForWatch(done, total),
                    done: done,
                    total: total,
                    footnote: PhoneCopy.tapAddOnWatchDetail
                )
            }
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
    private func tap(_ tap: PhoneAddWatchTap) { Task { await model.handleAddWatchTap(tap) } }
}
#endif
