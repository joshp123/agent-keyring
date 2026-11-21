// Written by AI on 2026.11.19 by model Claude Opus 5.5; for the direct join and adding Apple Watch on 2026.11.21.
// First run on the iPhone and adding Apple Watch, through the sequences that
// went wrong on Josh's phone or that his flow depends on: the iPhone asking his
// Mac by itself, asking again after he left the app or after the Mac said no,
// a second practice request made when he came back, the result jumping away
// before he had read it, and Face ID asked for Apple Watch with no end.

import AgentKeyringApprovalUI
import Foundation
import Testing

@Suite("iPhone first run")
struct PhoneFirstRunTests {
    func run(_ start: PhoneFirstRun, _ events: PhoneFirstRun.Event...) -> PhoneFirstRun {
        events.reduce(start) { $0.on($1) }
    }

    /// 20 Nov: it asked to join 0.03 seconds after opening, and again when he came back to the app.
    @Test("Nothing is asked of the Mac until Connect, and the request is picked up after leaving the app")
    func joinIsHisAndSurvivesLeaving() {
        let found = run(.start, .macFound(name: "MacBook Pro"))
        #expect(found == .foundMac(name: "MacBook Pro"))
        #expect(!found.mayJoin)
        let waiting = found.on(.connect)
        #expect(waiting.mayJoin)
        #expect(waiting.restored == waiting)
    }

    /// The audit of 21 Nov: a refusal or an expiry looped back into asking again by itself.
    @Test("A refused or expired join is never asked again without Ask Again")
    func refusalAndExpiryWaitForHim() {
        let waiting = PhoneFirstRun.waitingForMac(name: "MacBook Pro")
        for ended in [waiting.on(.joinRefused), waiting.on(.joinExpired)] {
            #expect(!ended.mayJoin)
            #expect(run(ended, .macFound(name: "MacBook Pro"), .lookedLong) == ended)
            #expect(ended.on(.askAgain).mayJoin)
        }
    }

    /// 20 Nov: leaving the app and coming back made a second practice request and lost the first.
    @Test("A practice request is picked up by its id after leaving or relaunching, never made again")
    func practiceKeepsItsID() {
        let sent = run(.practiceOffer, .sendPractice(id: "a1"), .practiceArrived(pushExpected: true))
        #expect(sent.practiceID == "a1")
        #expect(sent.restored == .practiceWaiting(id: "a1", arrived: false))
        #expect(PhoneFirstRun.practice(id: "a1").restored.practiceID == "a1")
        #expect(run(sent, .practiceSent(id: "b2")).practiceID == "b2")
    }

    /// 20 Nov: "the first example popup immediately disappears ... app immediately jumps screen".
    @Test("The practice's result stays on screen, across a relaunch, until he goes on")
    func resultStays() {
        let result = PhoneFirstRun.practiceResult(.denied)
        #expect(run(result, .practiceArrived(pushExpected: true), .practiceTimedOut(pushAddress: true)) == result)
        #expect(result.restored == result)
    }
}

@Suite("Adding Apple Watch")
struct PhoneAddWatchTests {
    /// His order: Face ID first, held with a shown end, asked again with its reason when it lapses.
    @Test("The Face ID confirmation is held until its end, and only then is Face ID asked again")
    func confirmationIsHeldThenLapses() {
        let until = Date(timeIntervalSince1970: 1000)
        let waiting = PhoneAddWatch.faceIDFirst.on(.confirmed(until: until))
        #expect(waiting == .waitingForWatch(until: until))
        #expect(waiting.watchMayAsk)
        #expect(waiting.on(.confirmationLapsed) == .faceIDExpired)
        #expect(!PhoneAddWatch.faceIDExpired.watchMayAsk)
        let passcode = waiting.on(.watchHasNoPasscode)
        #expect(passcode.on(.tryAgain(now: Date(timeIntervalSince1970: 500))) == waiting)
        #expect(passcode.on(.tryAgain(now: Date(timeIntervalSince1970: 2000))) == .faceIDExpired)
    }

    @Test("Apple Watch listed but its copies not sent is its own state, and Try Again sends only the copies")
    func copiesFailedIsExplicit() {
        let failed = PhoneAddWatch.encrypting(done: 10, total: 547).on(.copiesFailed(reason: "offline"))
        #expect(failed == .copiesFailed(reason: "offline"))
        #expect(failed.on(.watchAsked(total: 547)) == .encrypting(done: 0, total: 547))
    }
}
