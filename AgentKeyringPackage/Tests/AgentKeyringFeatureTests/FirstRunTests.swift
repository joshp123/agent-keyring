// Written by AI on 2026.11.19 by model claude opus 5.5; rewritten on 2026.11.20 for the one journey.
// First run through what happened on Josh's own devices: the Mac showed "Add
// your Apple Watch" after the Watch had joined from the iPhone, and stood
// still while the iPhone finished its own steps.

@testable import AgentKeyringFeature
import Foundation
import Testing

struct FirstRunTests {
    let phoneAndWatch = FirstRun.Devices(iPhone: true, watch: true, computers: false)

    @Test("His choice builds the steps; a Mac on its own has no device steps")
    func stepsFromHisChoice() {
        #expect(FirstRun.welcome.after(.getStarted) == .chooseDevices)
        #expect(FirstRun.chooseDevices.after(.chose(phoneAndWatch)).journey ==
            [.welcome, .chooseDevices, .practice, .passwords, .agents, .alwaysOn, .iPhone, .watch, .tryDevices, .ready])
        #expect(FirstRun.chooseDevices.after(.chose(.thisMacAlone)).journey ==
            [.welcome, .chooseDevices, .practice, .passwords, .agents, .tryDevices, .ready])
    }

    @Test("The iPhone finishing moves the Mac on; a Watch already added from the iPhone is passed over")
    func otherDevicesMoveTheMac() {
        let addPhone = FirstRun.journey(phoneAndWatch, .addPhone)
        #expect(addPhone.after(.deviceDone, facts: .init(alwaysOn: true)) == addPhone)
        #expect(addPhone.after(.deviceDone, facts: .init(alwaysOn: true, iPhoneDone: true, watchDone: true))
            == .journey(phoneAndWatch, .tryDevices))
        #expect(addPhone.after(.continueOn, facts: .init(alwaysOn: true, watchDone: true)) == .journey(phoneAndWatch, .tryDevices))
    }

    @MainActor @Test("A restart resumes where he was; a Mac that finished stays finished")
    func restart() {
        let settings = UserDefaults(suiteName: "FirstRunTests.restart")!
        settings.removePersistentDomain(forName: "FirstRunTests.restart")
        settings.set(try? JSONEncoder().encode(FirstRun.journey(phoneAndWatch, .addWatch)), forKey: MirrorAppModel.firstRunKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == .journey(phoneAndWatch, .addWatch))
        settings.set(Data(#"{"finished":{}}"#.utf8), forKey: MirrorAppModel.firstRunKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == .finished)
        settings.set(Data("from a later build".utf8), forKey: MirrorAppModel.firstRunKey)
        #expect(MirrorAppModel.savedFirstRun(settings) == .welcome)
    }
}
