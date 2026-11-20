// Written by AI on 2026.11.19 by model Claude Opus 5.5; the join and practice identity on 2026.11.20.
// First run on the iPhone, through the sequences that went wrong on Josh's
// phone: the iPhone asking his Mac by itself the moment it opened, asking
// again after he left the app, a second practice request made when he came
// back, and the result jumping away before he had read it.

import AgentKeyringApprovalUI
import Testing

@Suite("iPhone first run")
struct PhoneFirstRunTests {
    func run(_ start: PhoneFirstRun, _ events: PhoneFirstRun.Event...) -> PhoneFirstRun {
        events.reduce(start) { $0.on($1) }
    }

    /// 20 Nov: it asked to join 0.03 seconds after opening, and again when he came back to the app.
    @Test("Nothing is asked of the Mac until Add This iPhone, and the request is picked up after leaving the app")
    func joinIsHisAndSurvivesLeaving() {
        #expect(!PhoneFirstRun.start.mayJoin)
        #expect(run(.start, .noMac(longWait: false), .joinWaiting(mac: nil)) == .start)
        let waiting = run(.start, .addThisPhone, .joinWaiting(mac: "MacBook Pro"))
        #expect(waiting.mayJoin)
        #expect(waiting.restored == .linking(.startOnMac(longWait: false)))
        #expect(waiting.restored.mayJoin)
    }

    /// 20 Nov: leaving the app and coming back made a second practice request and lost the first.
    @Test("A practice request is picked up by its id after leaving or relaunching, never made again")
    func practiceKeepsItsID() {
        let sent = run(.practiceOffer, .sendPractice(id: "a1"), .practiceArrived(pushExpected: true))
        #expect(sent.practiceID == "a1")
        #expect(sent.restored == .practiceWaiting(id: "a1", arrived: false))
        #expect(PhoneFirstRun.practice(id: "a1").restored.practiceID == "a1")
        // The relay may answer with the request already waiting: first run follows that one.
        #expect(run(sent, .practiceSent(id: "b2")).practiceID == "b2")
    }

    /// 20 Nov: "the first example popup immediately disappears ... app immediately jumps screen".
    @Test("The practice's result stays on screen, across a relaunch, until he goes on")
    func resultStays() {
        let result = PhoneFirstRun.practiceResult(.denied)
        #expect(run(result, .practiceArrived(pushExpected: true), .practiceTimedOut(pushAddress: true)) == result)
        #expect(result.restored == result)
        #expect(result.on(.sendPractice(id: "c3")) == .practiceWaiting(id: "c3", arrived: false))
    }

    @Test("Once the Mac refuses, the iPhone does not ask again until Ask Again")
    func refusalOutlastsTheLook() {
        let refused = run(.start, .addThisPhone, .joinWaiting(mac: nil), .joinRefused(mac: nil), .noMac(longWait: true), .joinWaiting(mac: nil))
        #expect(refused == .linking(.denied(mac: nil)))
        #expect(!refused.mayJoin)
        #expect(refused.on(.askAgain).mayJoin)
    }
}
