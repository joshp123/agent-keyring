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

    @Test("Opening the app, being approved on the Mac, allowing notifications and approving the practice ends on Ready")
    func theBoardsPath() {
        let end = run(.start, .noMac(longWait: false), .joinWaiting(mac: nil), .joined, .continueTapped,
                      .notificationsAnswered(allowed: true), .practiceArrived(pushExpected: true), .practiceTapped, .practiceEnded)
        #expect(end == .ready)
        #expect(end.on(.done) == .finished)
    }

    /// Before: the practice's end was read only from its own stream. If that was lost while the
    /// app was away (he answered from the Lock Screen), first run stayed on a screen with no button.
    @Test("A practice answered while its own stream was lost still ends first run, from the work stream")
    func practiceEndSeenOnTheWorkStream() {
        #expect(run(.practiceWaiting(arrived: true), .practiceEnded) == .ready)
        #expect(run(.practiceWaiting(arrived: false), .practiceEnded) == .ready)
    }

    @Test("After a relaunch mid-practice, first run asks for a practice request again")
    func relaunchMidPractice() {
        for stage in [PhoneFirstRun.practice, .practiceWaiting(arrived: true), .settingUpNotifications, .practiceNotArrived] {
            #expect(stage.restored == .practiceWaiting(arrived: false))
            #expect(stage.restored.wantsPractice)
        }
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
                == .practiceWaiting(arrived: false))
        #expect(run(.finished, .notificationsAnswered(allowed: false)) == .finished)
        #expect(run(.practice, .done) == .practice)
        #expect(run(.notifications, .practiceEnded) == .notifications)
    }

    @Test("Notifications turned on in Settings, or Continue Without, both go on to the practice request")
    func notificationsOff() {
        #expect(run(.askingNotifications, .notificationsAnswered(allowed: false)) == .notificationsOff)
        #expect(run(.notificationsOff, .notificationsAnswered(allowed: true)) == .practiceWaiting(arrived: false))
        #expect(run(.notificationsOff, .continueWithoutNotifications, .practiceArrived(pushExpected: false)) == .practice)
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
