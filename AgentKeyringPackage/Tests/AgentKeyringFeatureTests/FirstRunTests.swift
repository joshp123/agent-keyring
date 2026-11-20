// Written by AI on 2026.11.19 by model claude opus 5.5; rewritten on 2026.11.20
// for the ten-step board "Mac".
// First run's state through the paths a person takes: everything added, this
// Mac alone, skipping the iPhone, a Mac already connected, the sample and then
// his own passwords, passwords that arrive while the practice request is up,
// and a restart.

@testable import AgentKeyringFeature
import Foundation
import Testing

struct FirstRunTests {
    @Test("Everything added: each window leads to the next, and Done finishes")
    func everythingAdded() {
        var state = FirstRun.welcome
        for event: FirstRun.Event in [.getStarted, .practicePassed, .imported(count: 542), .continueOn, .connected,
                                      .continueOn, .continueOn, .continueOn, .continueOn, .done] {
            state = state.after(event)
        }
        #expect(state == .finished)
        #expect(FirstRun.tellAgents(copied: .passwords(542)).after(.continueOn) == .stayingOn)
        #expect(FirstRun.stayingOn.after(.connected) == .addPhone)
        #expect(FirstRun.addPhone.after(.continueOn) == .addWatch)
        #expect(FirstRun.addWatch.after(.continueOn) == .addComputers)
        #expect(FirstRun.addComputers.after(.continueOn) == .tryDevices)
        #expect(FirstRun.tryDevices.after(.continueOn) == .ready)
    }

    @Test("Use This Mac Alone skips the iPhone, Apple Watch and other computers; skipping the iPhone skips the Watch")
    func skipping() {
        #expect(FirstRun.stayingOn.after(.useThisMacAlone) == .tryDevices)
        #expect(FirstRun.addPhone.after(.skip) == .addComputers)
        #expect(FirstRun.addWatch.after(.skip) == .addComputers)
    }

    @Test("A Mac already connected to a computer that stays on goes straight to adding the iPhone")
    func alreadyConnected() {
        #expect(FirstRun.tellAgents(copied: .sample).after(.continueOn, joined: true) == .addPhone)
    }

    @Test("From the sample, Copy Your Own Passwords goes back to copying, and his own copy replaces the sample")
    func sampleThenOwn() {
        let sample = FirstRun.copyPasswords.after(.useSample)
        #expect(sample == .tellAgents(copied: .sample))
        #expect(sample.after(.copyOwn) == .copyPasswords)
        #expect(FirstRun.ready.after(.copyOwn) == .copyPasswords)
        #expect(sample.after(.imported(count: 12)) == .tellAgents(copied: .passwords(12)))
    }

    @Test("Passwords arriving while the practice request is up leave it up")
    func outOfOrder() {
        #expect(FirstRun.practice.after(.imported(count: 3)) == .practice)
        #expect(FirstRun.welcome.after(.useSample) == .welcome)
        #expect(FirstRun.addPhone.after(.connected) == .addPhone)
    }

    @MainActor @Test("A restart resumes where he was; a state a later build cannot read starts at Welcome; a finished Mac stays finished")
    func restart() {
        let settings = UserDefaults(suiteName: "FirstRunTests.restart")!
        settings.removePersistentDomain(forName: "FirstRunTests.restart")
        settings.set(try? JSONEncoder().encode(FirstRun.addWatch), forKey: MirrorAppModel.firstRunKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == .addWatch)
        settings.set(Data("from a later build".utf8), forKey: MirrorAppModel.firstRunKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == .welcome)
        settings.set(try? JSONEncoder().encode(FirstRun.finished), forKey: MirrorAppModel.firstRunKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == .finished)
        settings.removePersistentDomain(forName: "FirstRunTests.restart")
    }
}
