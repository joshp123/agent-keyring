// Written by AI on 2026.11.19 by model Claude Opus 5.5; Add offered only while the iPhone waits, 2026.11.21.
// Apple Watch asks about notifications only once its iPhone has added it, and
// offers Add only while its iPhone holds a Face ID confirmation for it: before,
// it asked about notifications the first time it was opened, and sent its keys
// by itself whenever it opened.

import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import Testing

struct WatchSetupTests {
    func setup(listed: Bool = false, addOffered: Bool = false, addTapped: Bool = false,
               copiesPending: Bool = false, copyingToWatch: Bool = false,
               notifications: WatchNotificationPermission = .allowed, pushAddress: Bool = true,
               practiceAsked: Date? = nil, done: Bool = false) -> WatchOnboardingStep {
        WatchOnboardingStep(passcode: true, phoneJoined: true, listed: listed, addOffered: addOffered, addTapped: addTapped,
                   copiesPending: copiesPending, copyingToWatch: copyingToWatch,
                   notifications: notifications, pushAddress: pushAddress, practiceAsked: practiceAsked, practiceOfferDone: done,
                   now: Date(timeIntervalSince1970: 1000))
    }

    @Test func addIsOfferedOnlyWhileTheIPhoneWaits() {
        #expect(setup() == .startOnIPhone)
        #expect(setup(addOffered: true) == .readyToAdd)
        #expect(setup(addOffered: true, addTapped: true) == .preparing)
        #expect(setup(addOffered: false, addTapped: false, copyingToWatch: true) == .preparing)
        // Once the iPhone's Face ID confirmation expires, Watch must not stay trapped in Preparing forever.
        #expect(setup(addOffered: false, addTapped: true) == .startOnIPhone)
    }

    @Test func watchNeverFinishesSetupWhileCopiesArePending() {
        #expect(setup(listed: true, copiesPending: true, copyingToWatch: true) == .preparing)
        #expect(setup(listed: true, copiesPending: true, copyingToWatch: false) == .startOnIPhone)
        #expect(setup(listed: true, copiesPending: false, copyingToWatch: false) == .addedOfferPractice)
    }

    @Test func notificationsComeOnlyAfterTheIPhoneAddsIt() {
        #expect(setup(notifications: .notAsked) == .startOnIPhone)
        #expect(setup(listed: true, notifications: .notAsked) == .notifications)
    }

    @Test func thePracticeIsOfferedAgainIfItNeverCame() {
        #expect(setup(listed: true) == .addedOfferPractice)
        #expect(setup(listed: true, practiceAsked: Date(timeIntervalSince1970: 990)) == .practiceWaiting)
        #expect(setup(listed: true, practiceAsked: Date(timeIntervalSince1970: 900)) == .addedOfferPractice)
        #expect(setup(listed: true, done: true) == .ready)
        // Cold launch with nil pushToken before APNs registers must stay .ready once practiceOfferDone is true.
        #expect(setup(listed: true, pushAddress: false, done: true) == .ready)
    }

    @Test func requestLifecycleTransitionsAndExpiry() throws {
        #expect(CredentialRequestLifecycle.canTransition(from: .waiting, to: .approved))
        #expect(CredentialRequestLifecycle.canTransition(from: .approved, to: .ended))
        #expect(!CredentialRequestLifecycle.canTransition(from: .approved, to: .waiting))
        #expect(!CredentialRequestLifecycle.canTransition(from: .approved, to: .approved))
        #expect(!CredentialRequestLifecycle.canTransition(from: .ended, to: .approved))
        #expect(!CredentialRequestLifecycle.canTransition(from: .denied, to: .approved))

        var req = KeyringRequest()
        req.domain = "agentkeyring.request.v2"
        req.requestID = "r-life"
        req.askedUnixSeconds = 100
        req.answerByUnixSeconds = 700
        var envelope = Agentkeyring_V2_SignedRequestEnvelope()
        envelope.request = try req.serializedData()
        #expect(CredentialRequestLifecycle.isWaiting(envelope, now: Date(timeIntervalSince1970: 500)))
        #expect(CredentialRequestLifecycle.effectiveState(of: envelope, now: Date(timeIntervalSince1970: 500)) == .waiting)
        #expect(!CredentialRequestLifecycle.isWaiting(envelope, now: Date(timeIntervalSince1970: 700)))
        #expect(CredentialRequestLifecycle.effectiveState(of: envelope, now: Date(timeIntervalSince1970: 700)) == .unanswered)

        envelope.outcome.state = .approved
        envelope.outcome.notAfterUnixSeconds = 1000
        #expect(!CredentialRequestLifecycle.isWaiting(envelope, now: Date(timeIntervalSince1970: 800)))
        #expect(CredentialRequestLifecycle.effectiveState(of: envelope, now: Date(timeIntervalSince1970: 800)) == .approved)
        #expect(CredentialRequestLifecycle.effectiveState(of: envelope, now: Date(timeIntervalSince1970: 1000)) == .expired)
    }
}
