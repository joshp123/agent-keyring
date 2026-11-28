// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// The sandbox world the screens run on: no real secret can travel in a
// bundle, and every action ends the way it was set to, never silently.

import AgentKeyringApprovalCore
import AgentKeyringEngine
import AgentKeyringSealing
import Foundation
import Testing

@MainActor
@Suite struct SandboxWorldTests {
    @Test func aBundleNeverCarriesARealSecret() throws {
        var state = SandboxState.builtIn()
        state.logins[0].password = "correct horse battery staple"
        state.logins[0].totpSeed = "JBSWY3DPEHPK3PXP"
        var bundle = SandboxBundleCodec.bundle(from: state)
        #expect(bundle.logins.allSatisfy { $0.password == SandboxSecrets.password })
        #expect(bundle.logins[0].totpSeed == SandboxSecrets.totpSeed)

        // A bundle written by anything else is scrubbed again on the way in.
        bundle.logins[1].password = "leaked"
        bundle.logins[1].totpSeed = "LEAKEDSEED"
        let read = try SandboxBundleCodec.state(from: bundle.serializedData())
        #expect(read.logins.allSatisfy { $0.password == SandboxSecrets.password })
        #expect(read.logins[1].totpSeed == SandboxSecrets.totpSeed)
        #expect(read.logins.map(\.site) == state.logins.map(\.site))
        #expect(read.requests.map(\.request) == state.requests.map(\.request))
        #expect(read.listed == state.listed)
    }

    @Test func everyActionEndsAsItWasSet() async throws {
        let world = SandboxWorld()
        world.effects.outcomes[.approve] = .fail("Offline")
        await #expect(throws: SandboxFailure("Offline")) { try await world.approveAccessRequest("r1", on: .iPhone) }
        #expect(world.accessRequest("r1")?.state.isWaitingForYou == true)

        world.effects.outcomes[.approve] = .cancelled
        await #expect(throws: CancellationError.self) { try await world.approveAccessRequest("r1", on: .iPhone) }
        #expect(world.accessRequest("r1")?.state.isWaitingForYou == true)

        world.effects.outcomes[.approve] = .delayed(.seconds(3600))
        let waiting = Task { try await world.approveAccessRequest("r1", on: .iPhone) }
        while world.effects.ran.count < 3 { await Task.yield() }
        world.effects.cancelEffect(.approve)
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(world.accessRequest("r1")?.state.isWaitingForYou == true)

        world.effects.outcomes[.approve] = .immediate
        let state = try await world.approveAccessRequest("r1", on: .iPhone)
        guard case .approved(.iPhone, _) = state else { Issue.record("Not approved: \(state)"); return }
        // A late answer changes nothing.
        let late = try await world.denyAccessRequest("r1", reply: nil, on: .mac)
        #expect(late == state)
        #expect(world.effects.ran == [.approve, .approve, .approve, .approve, .deny])
    }

    @Test func removingAMacTakesItsComputerToo() async throws {
        let world = SandboxWorld()
        #expect(world.state.listed.approvers.first { $0.id == "macbook" }?.alsoAsks == true)
        #expect(!world.state.listed.computers.contains { $0.id == "macbook-agents" })
        try await world.removeDevice("macbook")
        #expect(!world.state.devices.contains { $0.id == "macbook" })
        #expect(!world.state.computers.contains { $0.id == "macbook-agents" })
        #expect(world.phoneSnapshot.devices.map(\.id) == ["iphone", "watch", "mini", "linux"])
    }

    @Test func blockingEndsItsGrantsAndDeletesItsPassword() async throws {
        let world = SandboxWorld()
        let github = world.state.logins[0].id
        world.set { $0.requests[1].request.state = .approved(by: .iPhone, until: .now.addingTimeInterval(600)) }
        let plan = world.plan(.blocked, for: [github])
        #expect(plan.willRevokeLeasesCount == 1)
        #expect(plan.willDeleteSecretsCount == 1)
        try await world.setLoginRule(.blocked, for: [github])
        #expect(world.state.logins[0].rule == .blocked && world.state.logins[0].secretDeleted)
        guard case .ended = world.state.requests[1].request.state else { Issue.record("Grant still live"); return }
    }

    @Test func blockingEndsARequestStillWaitingSoItCannotBeApproved() async throws {
        let world = SandboxWorld()
        let github = world.state.logins[0].id
        world.set { state in
            state.requests[1].loginID = github
            state.requests[1].request.state = .waitingForYou(until: .now.addingTimeInterval(600))
        }
        let id = world.state.requests[1].id
        try await world.setLoginRule(.blocked, for: [github])
        guard case .ended = world.state.requests[1].request.state else { Issue.record("Request still waiting"); return }
        let after = try await world.approveAccessRequest(id, on: .iPhone)
        guard case .ended = after else { Issue.record("Approved after Block: \(after)"); return }
    }

    @Test func settingsAndNotificationsStayInTheWorld() async throws {
        let world = SandboxWorld()
        let real = UserDefaults.standard.object(forKey: VersionCheck.noTelemetryKey) as? Bool
        var settings = world.phoneSnapshot.settings
        settings.anonymousTelemetry = false
        await world.savePhoneSettings(settings)
        #expect(world.phoneSnapshot.settings.anonymousTelemetry == false)
        #expect(UserDefaults.standard.object(forKey: VersionCheck.noTelemetryKey) as? Bool == real)
        world.set { $0.phone.notificationFacts = PhoneNotificationFacts() }
        #expect(await world.checkNotifications().asked == false)
        world.effects.outcomes[.askNotifications] = .fail("Not allowed")
        #expect(await world.askForNotifications() == false)
        world.effects.outcomes[.askNotifications] = .immediate
        #expect(await world.askForNotifications())
        let status = await world.checkNotifications()
        #expect(status.asked && status.facts.allowed)
        #expect(world.effects.ran == [.askNotifications, .askNotifications])
    }

    @Test func anIPhoneDumpKeepsWhereFirstRunStands() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyring = PhoneKeyringEngine(directory: directory, shared: PhoneSharedContext(accessGroup: nil), keys: NoKeys(),
                                   identity: { throw CancellationError() }, cloud: nil)
        let state = try PhoneKeyringEngine.sandboxState(from: keyring.sandboxBundle())
        #expect(state.phone.firstRun == .start)
        #expect(state.logins.isEmpty)
    }
}
