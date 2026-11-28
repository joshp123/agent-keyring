// Written by AI on 2026.11.19 by model claude opus 5.5; rewritten on 2026.11.21
// by the same model for the four local steps. Each test is a path Josh takes
// through the Mac's first run, or a restart in the middle of one.

@testable import AgentKeyringEngine
import AgentKeyringSealing
import Foundation
import Testing

struct FirstRunTests {
    @Test("Welcome to Show Passwords: practice, privacy, the test password, an agent's request, Ready")
    func theWholeWay() {
        let practice = UUID()
        var run = MacFirstRunFlow.welcome
        for event: MacFirstRunEvent in [.getStarted, .sendPractice(id: practice), .practiceApproved(id: practice), .continueOn,
                                      .continueOn, .useTestPasswordOnly, .agentAnswered(agent: "Claude Code", approved: true)] {
            run = run.after(event)
        }
        #expect(run.step == .connectAgent(.worked(agent: "Claude Code")))
        run = run.after(.continueOn)
        #expect(run.step == .ready)
        #expect(run.after(.showPasswords) == MacFirstRunFlow(step: .finished, practice: .approved))
    }

    @Test("Continue waits for an answer; a denial with his words counts, and he can send another")
    func practiceNeedsAnAnswer() {
        let first = UUID(), second = UUID()
        let notSent = MacFirstRunFlow(step: .practice)
        #expect(notSent.after(.continueOn) == notSent)
        let waiting = notSent.after(.sendPractice(id: first))
        #expect(waiting.after(.continueOn) == waiting)
        #expect(waiting.after(.sendPractice(id: second)) == waiting, "one practice request at a time")
        let denied = waiting.after(.practiceDenied(id: first, reply: "Use the invoice in Downloads."))
        #expect(denied.practice == .denied(reply: "Use the invoice in Downloads."))
        #expect(denied.after(.continueOn).step == .privacy)
        #expect(denied.after(.continueOn).after(.continueOn).step == .copy)
        #expect(denied.after(.sendPractice(id: second)).practice == .waiting(id: second))
    }

    @Test("A late answer to an earlier practice request moves nothing")
    func lateAnswer() {
        let old = UUID(), new = UUID()
        let waiting = MacFirstRunFlow(step: .practice, practice: .waiting(id: new))
        #expect(waiting.after(.practiceApproved(id: old)) == waiting)
        #expect(waiting.after(.practiceDenied(id: old, reply: "")) == waiting)
    }

    @Test("Back keeps his practice answer, so Continue still works")
    func backKeepsTheAnswer() {
        let copy = MacFirstRunFlow(step: .copy, practice: .denied(reply: ""))
        let privacy = copy.after(.back)
        #expect(privacy == MacFirstRunFlow(step: .privacy, practice: .denied(reply: "")))
        let back = privacy.after(.back)
        #expect(back == MacFirstRunFlow(step: .practice, practice: .denied(reply: "")))
        #expect(back.after(.continueOn) == privacy)
        #expect(privacy.after(.continueOn) == copy)
        #expect(back.after(.back) == .welcome)
    }

    @Test("Only the first agent request after he reaches Connect an agent is its outcome")
    func firstAgentRequestOnly() {
        let connect = MacFirstRunFlow(step: .connectAgent(.notTried), practice: .approved)
        let denied = connect.after(.agentAnswered(agent: "Codex", approved: false))
        #expect(denied.step == .connectAgent(.denied(agent: "Codex")))
        #expect(denied.after(.agentAnswered(agent: "Claude Code", approved: true)) == denied)
        #expect(denied.after(.skipTest) == denied, "Skip the Test is only before an outcome")
        #expect(connect.after(.skipTest).step == .ready)
        #expect(connect.after(.continueOn) == connect, "Continue comes with an outcome")
    }

    @Test("Show Passwords is the only way to finish")
    func onlyShowPasswordsFinishes() {
        let ready = MacFirstRunFlow(step: .ready, practice: .approved)
        for event: MacFirstRunEvent in [.continueOn, .skipTest, .getStarted, .useTestPasswordOnly] {
            #expect(ready.after(event) == ready)
        }
        #expect(ready.after(.showPasswords).step == .finished)
    }

    @MainActor @Test("A restart resumes where he was, without sending a practice request by itself")
    func restart() {
        let settings = UserDefaults(suiteName: "FirstRunTests.restart")!
        settings.removePersistentDomain(forName: "FirstRunTests.restart")
        #expect(MacKeyringEngine.savedFirstRun(settings) == .welcome)
        settings.set(try? MacFirstRunFlow(step: .ready, practice: .approved).encodeProtobuf(), forKey: MacKeyringEngine.firstRunKey)
        #expect(MacKeyringEngine.savedFirstRun(settings) == MacFirstRunFlow(step: .ready, practice: .approved))
        settings.set(try? MacFirstRunFlow(step: .practice, practice: .waiting(id: UUID())).encodeProtobuf(), forKey: MacKeyringEngine.firstRunKey)
        #expect(MacKeyringEngine.savedFirstRun(settings) == MacFirstRunFlow(step: .practice))
    }

    @MainActor @Test("His words in a practice denial, and an agent's name, never reach the diagnostic log")
    func denialWordsStayOutOfTheLog() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let model = MacKeyringEngine(store: MacVaultFileStore(directory: folder.appending(path: "logins")),
                                   accessControl: CredentialAccessController(store: LoginRuleStore(read: { nil }, write: { _ in })),
                                   leaseStore: CredentialLeaseStore(persistence: LeasePersistence(directory: folder.appending(path: "leases"))),
                                   settings: settings)
        let practice = UUID()
        for event: MacFirstRunEvent in [.getStarted, .sendPractice(id: practice), .practiceDenied(id: practice, reply: "Use the invoice in Downloads."),
                                      .continueOn, .continueOn, .useTestPasswordOnly, .agentAnswered(agent: "Secret Agent", approved: false)] {
            model.sendFirstRunEvent(event)
        }
        #expect(model.firstRun.step == .connectAgent(.denied(agent: "Secret Agent")))
        let lines = KeyringDiagnosticLog.mac.lines(last: .max).filter { $0.contains(" firstrun moved ") }
        #expect(lines.contains { $0.contains("practiceDenied(\(practice))") })
        #expect(!lines.contains { $0.contains("invoice") || $0.contains("Secret Agent") })
    }

    @Test("Changes are counted against the list last sent: added, changed by date, and removed")
    func changesSinceTheListLastSent() {
        let monday = Date(timeIntervalSince1970: 1_800_000_000), tuesday = monday.addingTimeInterval(86_400)
        let sent: [String: Date?] = ["kept": monday, "edited": monday, "gone": monday, "test": nil]
        let now: [String: Date?] = ["kept": monday, "edited": tuesday, "new": tuesday, "test": nil]
        #expect(UnsentVaultChanges(sent: sent, now: now) == UnsentVaultChanges(added: 1, changed: 1, removed: 1))
        // A password with no last-changed date never counts as changed.
        #expect(UnsentVaultChanges(sent: ["a": nil], now: ["a": tuesday]) == UnsentVaultChanges())
    }
}
