// Written by AI on 2026.11.19 by model claude opus 5.5; rewritten on 2026.11.21
// by the same model for the four local steps. Each test is a path Josh takes
// through the Mac's first run, or a restart in the middle of one.

@testable import AgentKeyringFeature
import Foundation
import Testing

struct FirstRunTests {
    @Test("Welcome to Show Passwords: practice, the test password, an agent's request, Ready")
    func theWholeWay() {
        let practice = UUID()
        var run = FirstRun.welcome
        for event: FirstRun.Event in [.getStarted, .sendPractice(id: practice), .practiceApproved(id: practice), .continueOn,
                                      .useTestPasswordOnly, .agentAnswered(agent: "Claude Code", approved: true)] {
            run = run.after(event)
        }
        #expect(run.step == .connectAgent(.worked(agent: "Claude Code")))
        run = run.after(.continueOn)
        #expect(run.step == .ready)
        #expect(run.after(.showPasswords) == FirstRun(step: .finished, practice: .approved))
    }

    @Test("Continue waits for an answer; a denial with his words counts, and he can send another")
    func practiceNeedsAnAnswer() {
        let first = UUID(), second = UUID()
        let notSent = FirstRun(step: .practice)
        #expect(notSent.after(.continueOn) == notSent)
        let waiting = notSent.after(.sendPractice(id: first))
        #expect(waiting.after(.continueOn) == waiting)
        #expect(waiting.after(.sendPractice(id: second)) == waiting, "one practice request at a time")
        let denied = waiting.after(.practiceDenied(id: first, reply: "Use the invoice in Downloads."))
        #expect(denied.practice == .denied(reply: "Use the invoice in Downloads."))
        #expect(denied.after(.continueOn).step == .copy)
        #expect(denied.after(.sendPractice(id: second)).practice == .waiting(id: second))
    }

    @Test("A late answer to an earlier practice request moves nothing")
    func lateAnswer() {
        let old = UUID(), new = UUID()
        let waiting = FirstRun(step: .practice, practice: .waiting(id: new))
        #expect(waiting.after(.practiceApproved(id: old)) == waiting)
        #expect(waiting.after(.practiceDenied(id: old, reply: "")) == waiting)
    }

    @Test("Back keeps his practice answer, so Continue still works")
    func backKeepsTheAnswer() {
        let copy = FirstRun(step: .copy, practice: .denied(reply: ""))
        let back = copy.after(.back)
        #expect(back == FirstRun(step: .practice, practice: .denied(reply: "")))
        #expect(back.after(.continueOn) == copy)
        #expect(back.after(.back) == .welcome)
    }

    @Test("Only the first agent request after he reaches Connect an agent is its outcome")
    func firstAgentRequestOnly() {
        let connect = FirstRun(step: .connectAgent(.notTried), practice: .approved)
        let denied = connect.after(.agentAnswered(agent: "Codex", approved: false))
        #expect(denied.step == .connectAgent(.denied(agent: "Codex")))
        #expect(denied.after(.agentAnswered(agent: "Claude Code", approved: true)) == denied)
        #expect(denied.after(.skipTest) == denied, "Skip the Test is only before an outcome")
        #expect(connect.after(.skipTest).step == .ready)
        #expect(connect.after(.continueOn) == connect, "Continue comes with an outcome")
    }

    @Test("Show Passwords is the only way to finish")
    func onlyShowPasswordsFinishes() {
        let ready = FirstRun(step: .ready, practice: .approved)
        for event: FirstRun.Event in [.continueOn, .skipTest, .getStarted, .useTestPasswordOnly] {
            #expect(ready.after(event) == ready)
        }
        #expect(ready.after(.showPasswords).step == .finished)
    }

    @MainActor @Test("A restart resumes where he was, without sending a practice request by itself")
    func restart() {
        let settings = UserDefaults(suiteName: "FirstRunTests.restart")!
        settings.removePersistentDomain(forName: "FirstRunTests.restart")
        #expect(MirrorAppModel.savedFirstRun(settings) == .welcome)
        settings.set(try? JSONEncoder().encode(FirstRun(step: .ready, practice: .approved)), forKey: MirrorAppModel.firstRunKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == FirstRun(step: .ready, practice: .approved))
        settings.set(try? JSONEncoder().encode(FirstRun(step: .practice, practice: .waiting(id: UUID()))), forKey: MirrorAppModel.firstRunKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == FirstRun(step: .practice))
        // An earlier build's finished first run stays finished; its journey of devices starts again.
        settings.set(Data(#"{"finished":{}}"#.utf8), forKey: MirrorAppModel.firstRunKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == .finished)
        settings.set(Data(#"{"journey":{"_0":{"iPhone":true,"watch":true,"computers":false},"_1":{"addWatch":{}}}}"#.utf8), forKey: MirrorAppModel.firstRunKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == .welcome)
        // A Mac that finished before first run was saved at all.
        settings.removeObject(forKey: MirrorAppModel.firstRunKey)
        settings.set(Date(), forKey: MirrorAppModel.testedAtKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == .finished)
    }

    @Test("Changes are counted against the list last sent: added, changed by date, and removed")
    func changesSinceTheListLastSent() {
        let monday = Date(timeIntervalSince1970: 1_800_000_000), tuesday = monday.addingTimeInterval(86_400)
        let sent: [String: Date?] = ["kept": monday, "edited": monday, "gone": monday, "test": nil]
        let now: [String: Date?] = ["kept": monday, "edited": tuesday, "new": tuesday, "test": nil]
        #expect(PasswordChanges(sent: sent, now: now) == PasswordChanges(added: 1, changed: 1, removed: 1))
        // A record made before dates were kept never counts a password as changed.
        #expect(PasswordChanges(sent: ["a": nil], now: ["a": tuesday]) == PasswordChanges())
    }

    @MainActor @Test("What is unsent survives a quit: the record of the list last sent is saved")
    func unsentSurvivesAQuit() {
        let settings = UserDefaults(suiteName: "FirstRunTests.unsent")!
        settings.removePersistentDomain(forName: "FirstRunTests.unsent")
        let monday = Date(timeIntervalSince1970: 1_800_000_000)
        MirrorAppModel.saveSentList(["a": monday, "b": nil], in: settings)
        #expect(MirrorAppModel.savedSentList(settings) == ["a": monday, "b": nil])
    }
}
