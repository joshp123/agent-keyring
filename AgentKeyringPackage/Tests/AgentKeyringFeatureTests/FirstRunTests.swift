// Written by AI on 2026.11.19 by model claude opus 5.5.
// First run's state through the things that really happen out of order:
// a late timer, a restart, an agent quicker than Josh, passwords that arrive
// while the practice request is up, and a Mac that finished before.

@testable import AgentKeyringFeature
import Foundation
import Testing

struct FirstRunTests {
    @Test("The five-minute timer firing after the passwords arrived changes nothing")
    func lateTimer() {
        let arrived = FirstRun.copyPasswords(.waiting).after(.importStarted).after(.imported(count: 542))
        #expect(arrived == .setUpAgents(copied: .passwords(542), messageCopied: false))
        #expect(arrived.after(.exportTimedOut) == arrived)
        // A second Open Passwords after five minutes waits again.
        #expect(FirstRun.copyPasswords(.noneArrived).after(.openPasswords) == .copyPasswords(.waiting))
    }

    @MainActor @Test("A restart in the middle of a copy or a wait resumes at Copy your passwords, never on Copying")
    func restart() {
        #expect(FirstRun.copying.resumed == .copyPasswords(.notOpened))
        #expect(FirstRun.copyPasswords(.waiting).resumed == .copyPasswords(.notOpened))
        #expect(FirstRun.practiceDenied(reply: "No").resumed == .practiceDenied(reply: "No"))
        let settings = UserDefaults(suiteName: "FirstRunTests.restart")!
        settings.removePersistentDomain(forName: "FirstRunTests.restart")
        settings.set(try? JSONEncoder().encode(FirstRun.copying), forKey: MirrorAppModel.firstRunKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == .copyPasswords(.notOpened))
        settings.set(Data("from a later build".utf8), forKey: MirrorAppModel.firstRunKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == .welcome)
    }

    @MainActor @Test("A Mac that finished first run before this state was saved opens as finished")
    func finishedBefore() {
        let settings = UserDefaults(suiteName: "FirstRunTests.finished")!
        settings.removePersistentDomain(forName: "FirstRunTests.finished")
        settings.set(true, forKey: MirrorAppModel.firstRunFinishedKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == .finished)
    }

    @Test("An agent that ran install before he reached Set up your agents does not leave him waiting")
    func agentFirst() {
        let entered = FirstRun.copyPasswords(.notOpened).after(.useSample)
        #expect(entered.settled(agentsSetUp: true) == .computers)
        #expect(entered.settled(agentsSetUp: false) == .setUpAgents(copied: .sample, messageCopied: false))
    }

    @Test("Passwords arriving while the practice request is up leave it up; his own copy replaces the sample later")
    func outOfOrder() {
        #expect(FirstRun.practice.after(.importStarted) == .practice)
        let sample = FirstRun.setUpAgents(copied: .sample, messageCopied: true)
        #expect(sample.after(.imported(count: 12)) == .setUpAgents(copied: .passwords(12), messageCopied: true))
    }
}
