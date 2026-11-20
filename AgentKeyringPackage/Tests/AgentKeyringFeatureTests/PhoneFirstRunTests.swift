// Written by AI on 2026.11.19 by model Claude Opus 5.5.
// First run on the iPhone, through the event sequences that reached a wrong
// state in the build before it became one explicit state: a practice request
// whose own stream was lost, a relaunch in the middle, a refusal followed by
// the look for the Mac, and a late or repeated answer.

import AgentKeyringApprovalUI
import Testing

@Suite("iPhone first run")
struct PhoneFirstRunTests {
    func run(_ start: PhoneFirstRun, _ events: PhoneFirstRun.Event...) -> PhoneFirstRun {
        events.reduce(start) { $0.on($1) }
    }

    @Test("The board's path: approved on the Mac, notifications on, a practice he sends himself, its result, then Apple Watch")
    func theBoardsPath() {
        let result = run(.start, .noMac(longWait: false), .joinWaiting(mac: nil), .joined, .continueTapped,
                         .notificationsAnswered(allowed: true), .sendPractice, .practiceArrived(pushExpected: true), .practiceTapped,
                         .practiceEnded(.approved))
        #expect(result == .practiceResult(.approved))
        #expect(result.on(.continueAfterPractice(watchToAdd: true)) == .addWatch)
        #expect(result.on(.continueAfterPractice(watchToAdd: true)).on(.watchDone) == .finished)
        #expect(result.on(.continueAfterPractice(watchToAdd: false)) == .finished)
    }

    /// Josh, 20 Nov: "the first example popup immediately disappears when you click approve on iphone ... app immediately jumps screen".
    @Test("The practice's result stays on screen until he goes on, and Send Another sends a new one")
    func resultStays() {
        let result = PhoneFirstRun.practiceResult(.denied)
        #expect(run(result, .practiceArrived(pushExpected: true), .practiceTimedOut(pushAddress: true), .noMac(longWait: true)) == result)
        #expect(result.on(.sendPractice) == .practiceWaiting(arrived: false))
        #expect(PhoneFirstRun.practiceOffer.on(.practiceArrived(pushExpected: false)) == .practiceOffer)
    }

    /// Before: the practice's end was read only from its own stream. If that was lost while the
    /// app was away (he answered from the Lock Screen), first run stayed on a screen with no button.
    @Test("A practice answered while its own stream was lost still ends first run, from the work stream")
    func practiceEndSeenOnTheWorkStream() {
        #expect(run(.practiceWaiting(arrived: true), .practiceEnded(.approved)) == .practiceResult(.approved))
        #expect(run(.practiceWaiting(arrived: false), .practiceEnded(.noAnswer)) == .practiceResult(.noAnswer))
    }

    @Test("After a relaunch mid-practice, first run offers the practice request again")
    func relaunchMidPractice() {
        for stage in [PhoneFirstRun.practice, .practiceWaiting(arrived: true), .settingUpNotifications, .practiceNotArrived, .practiceResult(.approved)] {
            #expect(stage.restored == .practiceOffer)
            #expect(!stage.restored.wantsPractice)
        }
        #expect(PhoneFirstRun.addWatch.restored == .addWatch)
        #expect(PhoneFirstRun.askingNotifications.restored == .notifications)
        #expect(PhoneFirstRun.welcome(.approveOnMac(mac: nil), practising: true).restored == .start)
        #expect(PhoneFirstRun.finished.restored == .finished)
    }

    /// The look for the Mac runs every three seconds and reports what it found; a refusal must outlast it.
    @Test("Once the Mac refuses, the iPhone does not ask again until Ask Again")
    func refusalOutlastsTheLook() {
        let refused = run(.start, .joinWaiting(mac: "MacBook Pro"), .joinRefused(mac: "MacBook Pro"),
                          .noMac(longWait: false), .noMac(longWait: true), .joinWaiting(mac: nil))
        #expect(refused == .welcome(.denied(mac: "MacBook Pro"), practising: false))
        #expect(!refused.mayJoin)
        #expect(refused.on(.askAgain).mayJoin)
    }

    @Test("No practice request: the cause after 30 seconds, then on by itself")
    func practiceThatDoesNotArrive() {
        // Apple gave no push address: no push will come, so it opens by itself when it arrives.
        #expect(run(.practiceWaiting(arrived: false), .practiceTimedOut(pushAddress: false), .practiceArrived(pushExpected: false)) == .practice)
        // An address but nothing came: the computer that stays on is the cause; Try Again asks afresh.
        let notArrived = run(.practiceWaiting(arrived: false), .practiceTimedOut(pushAddress: true))
        #expect(notArrived == .practiceNotArrived)
        #expect(notArrived.on(.tryAgain) == .practiceWaiting(arrived: false))
        // It arrived but he did not tap its notification: it opens by itself at 30 seconds.
        #expect(run(.practiceWaiting(arrived: false), .practiceArrived(pushExpected: true), .practiceTimedOut(pushAddress: true)) == .practice)
    }

    @Test("A second Continue, a late answer from iOS or an early Done moves nothing")
    func repeatedAndLateEvents() {
        #expect(run(.notifications, .continueTapped, .continueTapped) == .askingNotifications)
        // The app reads iOS's answer again when it comes back to the front; the dialog also returns it.
        #expect(run(.askingNotifications, .notificationsAnswered(allowed: true), .notificationsAnswered(allowed: true))
                == .practiceOffer)
        #expect(run(.finished, .notificationsAnswered(allowed: false)) == .finished)
        #expect(run(.practice, .watchDone) == .practice)
        #expect(run(.notifications, .practiceEnded(.approved)) == .notifications)
        #expect(run(.finished, .sendPractice) == .finished)
    }

    @Test("Notifications turned on in Settings, or Continue Without, both go on to the practice request")
    func notificationsOff() {
        #expect(run(.askingNotifications, .notificationsAnswered(allowed: false)) == .notificationsOff)
        #expect(run(.notificationsOff, .notificationsAnswered(allowed: true)) == .practiceOffer)
        #expect(run(.notificationsOff, .continueWithoutNotifications, .sendPractice, .practiceArrived(pushExpected: false)) == .practice)
    }

    @Test("The practice before joining opens over the first screen and closes back to it")
    func practiceBeforeJoining() {
        let open = run(.start, .tryPractice)
        #expect(open == .welcome(.startOnMac(longWait: false), practising: true))
        #expect(open.on(.noMac(longWait: true)) == .welcome(.startOnMac(longWait: true), practising: true))
        #expect(open.on(.closePractice) == .start)
    }

    @Test("This iPhone taken out of the list of devices starts again at the first screen, from anywhere")
    func removed() {
        for stage in [PhoneFirstRun.finished, .practice, .notificationsOff, .welcome(.denied(mac: nil), practising: false)] {
            #expect(stage.on(.removed) == .start)
        }
    }
}
