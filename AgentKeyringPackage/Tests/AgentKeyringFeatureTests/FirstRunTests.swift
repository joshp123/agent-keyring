// Written by AI on 2026.11.19 by model claude opus 5.5; rewritten on 2026.11.20.
// First run's state through the things that really happen out of order: an
// agent quicker than Josh, the sample and then his own passwords, passwords
// that arrive while the practice request is up, a restart, and links that
// change behind the app's back.

@testable import AgentKeyringFeature
import Foundation
import Testing

struct FirstRunTests {
    @Test("Continue waits for the agents on this Mac, and goes at once if they were set up before he got there")
    func continueWaitsForAgents() {
        let setUp = FirstRun.copyPasswords.after(.imported(count: 542), agentsSetUp: false)
        #expect(setUp == .setUpAgents(copied: .passwords(542)))
        #expect(setUp.after(.continueOn, agentsSetUp: false) == setUp)
        #expect(setUp.after(.continueOn, agentsSetUp: true) == .ready)
    }

    @Test("From the sample, Copy Your Own Passwords goes back to copying, and his own copy replaces the sample")
    func sampleThenOwn() {
        let sample = FirstRun.copyPasswords.after(.useSample, agentsSetUp: false)
        #expect(sample == .setUpAgents(copied: .sample))
        #expect(sample.after(.copyOwn, agentsSetUp: false) == .copyPasswords)
        #expect(FirstRun.ready.after(.copyOwn, agentsSetUp: true) == .copyPasswords)
        #expect(FirstRun.copyPasswords.after(.imported(count: 12), agentsSetUp: true) == .setUpAgents(copied: .passwords(12)))
        // Passwords that arrive while "Set up your agents" shows the sample replace it there.
        #expect(sample.after(.imported(count: 12), agentsSetUp: false) == .setUpAgents(copied: .passwords(12)))
    }

    @Test("Passwords arriving while the practice request is up leave it up")
    func outOfOrder() {
        #expect(FirstRun.practice.after(.imported(count: 3), agentsSetUp: false) == .practice)
        #expect(FirstRun.welcome.after(.useSample, agentsSetUp: false) == .welcome)
    }

    @MainActor @Test("A restart resumes where he was; a state a later build cannot read starts at Welcome")
    func restart() {
        let settings = UserDefaults(suiteName: "FirstRunTests.restart")!
        settings.removePersistentDomain(forName: "FirstRunTests.restart")
        settings.set(try? JSONEncoder().encode(FirstRun.setUpAgents(copied: .sample)), forKey: MirrorAppModel.firstRunKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == .setUpAgents(copied: .sample))
        settings.set(Data("from a later build".utf8), forKey: MirrorAppModel.firstRunKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == .welcome)
        settings.removePersistentDomain(forName: "FirstRunTests.restart")
        settings.set(true, forKey: MirrorAppModel.firstRunFinishedKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == .finished)
    }

    @Test("Agents count as set up only while the command on their path is this app's, whoever changed it")
    func agentsFromTheLinks() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "FirstRunTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let helper = home.appending(path: "Agent Keyring.app/Contents/Helpers/agent-keyring")
        let earlier = home.appending(path: "AgentKeyring.app/Contents/Helpers/agent-keyring")
        let link = home.appending(path: ".local/bin/agent-keyring")
        for file in [helper, earlier] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(!AgentsOnThisMac.areSetUp(home: home, helper: helper))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
        #expect(AgentsOnThisMac.areSetUp(home: home, helper: helper))
        // `install --undo`, or a Nix switch, points it back at the earlier app.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: earlier)
        #expect(!AgentsOnThisMac.areSetUp(home: home, helper: helper))
    }
}
