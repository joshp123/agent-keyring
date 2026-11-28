// Written by AI on 2026.11.27 by model GPT-6.2 Sol.

import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
@testable import AgentKeyringEngine
import AgentKeyringProtocol
@testable import AgentKeyringSealing
import CryptoKit
import Foundation
import Testing

/// Check safety on every edge, then walk backwards from the exits along progress edges.
/// Breadth-first exploration gives each state its shortest trace.
private func verify<State: Equatable, Event>(
    from initial: State,
    bucket: (State) -> Int = { _ in 0 },
    events: (State) -> [Event],
    step: (State, Event) throws -> State,
    isExit: (State) -> Bool,
    isProgress: (State, Event) -> Bool = { _, _ in true },
    violation: (State, Event, State) -> String? = { _, _, _ in nil }
) throws {
    var states = [initial]
    var groups = [bucket(initial): [0]]
    var incoming: [[Int]] = [[]]
    var predecessor: [(Int, Event)?] = [nil]

    func trace(to index: Int, then event: Event? = nil) -> String {
        var steps = event.map { [String(describing: $0)] } ?? []
        var cursor = index
        while let (parent, event) = predecessor[cursor] {
            steps.append(String(describing: event))
            cursor = parent
        }
        return steps.isEmpty ? "(initial state)" : steps.reversed().joined(separator: " -> ")
    }

    var index = 0
    while index < states.count {
        let state = states[index]
        for event in events(state) {
            let next = try step(state, event)
            if let problem = violation(state, event, next) {
                Issue.record("\(problem). Shortest trace: \(trace(to: index, then: event))")
                return
            }
            if next == state { continue }
            let progress = isProgress(state, event)
            let key = bucket(next)
            if let found = groups[key]?.first(where: { states[$0] == next }) {
                if progress { incoming[found].append(index) }
            } else {
                groups[key, default: []].append(states.count)
                states.append(next)
                incoming.append(progress ? [index] : [])
                predecessor.append((index, event))
            }
        }
        index += 1
    }

    var canExit = states.indices.filter { isExit(states[$0]) }
    var reached = Set(canExit)
    index = 0
    while index < canExit.count {
        for prior in incoming[canExit[index]] where reached.insert(prior).inserted {
            canExit.append(prior)
        }
        index += 1
    }
    if let trapped = states.indices.first(where: { !reached.contains($0) }) {
        Issue.record("No progress route to an exit. Shortest trace: \(trace(to: trapped))")
    }
}

private enum RunEvent<Event> { case deliver(Event), restart }

@Suite("Bounded state-space verification")
struct StateSpaceVerificationTests {
    private static let ids = [
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)),
    ]

    @Test func macFirstRun() throws {
        let taps: [MacFirstRunEvent] = [
            .getStarted, .back, .continueOn, .useTestPasswordOnly, .skipTest, .showPasswords,
            .agentAnswered(agent: "agent", approved: true), .agentAnswered(agent: "agent", approved: false),
        ]
        let callbacks: [MacFirstRunEvent] = Self.ids.flatMap { id in
            [.sendPractice(id: id), .practiceApproved(id: id), .practiceDenied(id: id, reply: "Denied")]
        }
        let events = (taps + callbacks).map(RunEvent<MacFirstRunEvent>.deliver) + [.restart]
        func advance(_ state: MacFirstRunFlow, _ event: RunEvent<MacFirstRunEvent>) -> MacFirstRunFlow {
            switch event {
            case let .deliver(event): state.after(event)
            case .restart: state.restored
            }
        }
        try verify(from: MacFirstRunFlow.welcome, events: { _ in events }, step: advance,
                   isExit: { $0.step == .finished }, violation: { state, _, next in
            state.step == .finished && next != state ? "First run reopened" : nil
        })
    }

    @Test func phoneFirstRun() throws {
        let events: [PhoneFirstRunEvent] = [
            .macFound(name: nil), .macFound(name: "Mac"), .macGone, .noMacFound, .havingTrouble,
            .tryAgain, .connect, .cancel, .joinRefused, .macUnreachable, .joinExpired, .askAgain, .joined,
            .passwordsReceived, .setUpHere, .passwordsImported, .continueTapped,
            .notificationsAnswered(allowed: true), .notificationsAnswered(allowed: false), .notificationsDone,
            .continueWithoutNotifications, .practiceArrived(pushExpected: true), .practiceArrived(pushExpected: false),
            .practiceTapped, .practiceDismissed, .practiceTimedOut(pushAddress: true), .practiceTimedOut(pushAddress: false),
            .practiceMacUnreachable, .practiceEnded(.approved), .practiceEnded(.denied), .practiceEnded(.noAnswer),
            .continueAfterPractice(watchToAdd: true), .continueAfterPractice(watchToAdd: false), .addAppleWatch, .addAComputer,
            .done, .removed,
        ] + ["first", "second"].flatMap { [.practiceSent(id: $0), .sendPractice(id: $0)] }
        let deliveries = events.map(RunEvent<PhoneFirstRunEvent>.deliver) + [.restart]
        try verify(from: PhoneFirstRun.start, bucket: { $0.hashValue },
                   events: { _ in deliveries }, step: { state, event in
            switch event {
            case let .deliver(event): state.on(event)
            case .restart: state.restored
            }
        }, isExit: { $0 == .finished }, isProgress: { _, event in
            switch event {
            case .deliver(.removed), .restart: false
            case .deliver: true
            }
        }, violation: { state, event, next in
            if case .deliver(.removed) = event { return next == .start ? nil : "Removal did not reset first run" }
            if state == .finished { return next == state ? nil : "First run reopened" }
            if case .practiceResult = state, next != state {
                switch event {
                case .deliver(.sendPractice), .deliver(.continueAfterPractice): break
                default: return "A late callback replaced a settled practice result"
                }
            }
            return nil
        })
    }

    @Test func addWatch() throws {
        let deadline = Date(timeIntervalSince1970: 10)
        let events: [PhoneAddWatchEvent] = [
            .checked(paired: false, installed: false), .checked(paired: true, installed: false),
            .checked(paired: true, installed: true), .confirmed(until: deadline), .confirmationLapsed,
            .watchHasNoPasscode, .tryAgain(now: deadline.addingTimeInterval(-1)), .tryAgain(now: deadline),
            .tryAgain(now: deadline.addingTimeInterval(1)), .watchAsked(total: 2),
            .encrypted(done: 1, total: 2), .encrypted(done: 2, total: 2), .copiesSent, .copiesFailed(reason: "Offline"),
            .cancel, .done,
        ]
        try verify(from: PhoneAddWatch.initialFlow(paired: false, installed: false), bucket: { $0.hashValue },
                   events: { _ in events }, step: { $0.on($1) }, isExit: { $0 == .added || $0 == .closed },
                   isProgress: { _, event in event != .cancel },
                   violation: { state, event, next in
            switch (state, event) {
            case (.waitingForWatch, .confirmationLapsed), (.watchNeedsPasscode, .confirmationLapsed):
                return next == .faceIDExpired && !next.watchMayAsk ? nil : "Expired confirmation still permits Add"
            case let (.watchNeedsPasscode(until), .tryAgain(now)) where now >= until:
                return next == .faceIDExpired ? nil : "Retry reused an expired confirmation"
            case (.closed, _) where next != .closed: return "A closed Add flow reopened"
            default: return nil
            }
        })
    }

    /// The iPhone's one sheet: every state can be closed, an ended request takes its sheet and its draft
    /// with it, a stale dismissal leaves a newer sheet alone, and Back and Cancel only undo what they name.
    @Test func phoneSheet() throws {
        let ids = ["a", "b"]
        var events: [PhoneSheetEvent] = [.backToDecide, .openAddWatch, .addWatchClosed, .openSettings, .settingsClosed,
                                                .dismissStaleNotice, .dismiss(expectedItem: nil), .dismiss(expectedItem: .addWatch),
                                                .dismiss(expectedItem: .settings)]
        for id in ids {
            for waiting in [true, false] {
                for note in [nil, "Ended"] as [String?] {
                    events += [.notificationTapped(id: id, isWaiting: waiting, endedNote: note),
                               .notificationApproveTapped(id: id, isWaiting: waiting, endedNote: note),
                               .notificationExplainTapped(id: id, isWaiting: waiting, endedNote: note)]
                }
            }
            events += [.openDecide(id: id), .openExplain(id: id), .openSettled(id: id), .approveStarted(id: id), .approveCancelled(id: id),
                       .requestEnded(id: id), .dismiss(expectedItem: .request(id: id)), .updateDraft(id: id, text: "Wait"),
                       .updateDraft(id: id, text: "")]
        }
        func ends(_ event: PhoneSheetEvent) -> String? {
            switch event {
            case let .requestEnded(id): id
            case let .notificationTapped(id, false, _), let .notificationApproveTapped(id, false, _),
                 let .notificationExplainTapped(id, false, _): id
            default: nil
            }
        }
        try verify(from: PhoneSheetState(), bucket: { $0.hashValue }, events: { _ in events }, step: { state, event in
            var next = state
            next.apply(event)
            return next
        }, isExit: { $0.presentation == .none }, violation: { state, event, next in
            if let id = ends(event) {
                if next.requestID == id { return "An ended request kept its sheet" }
                if next.drafts[id] != nil { return "An ended request kept its reply draft" }
            }
            if case let .dismiss(expected?) = event, expected != state.item, next != state { return "A stale dismissal closed a newer sheet" }
            if next.drafts.values.contains("") { return "An empty draft was kept" }
            if case .backToDecide = event, next != state, !state.canReturnToDecide { return "Back left a sheet it did not open" }
            if case .approveCancelled = event, next != state, state.requestMode != .approving { return "Cancel undid something other than approving" }
            if next.requestID != nil, next.requestID != state.requestID, next.staleNotice != nil { return "A new request opened under a stale note" }
            return nil
        })
    }

    @Test func macHardwareSetup() throws {
        let hardware: [MacHardware] = [.touchID, .noTouchID, .noSecureEnclave]
        let background: [MacHardwareSetupEvent] = [.keysMade, .keysFailed("Locked")] + hardware.flatMap {
            [.looked(keysSaved: false, hardware: $0), .looked(keysSaved: true, hardware: $0)]
        }
        try verify(from: MacHardwareSetupFlow.loading,
                   events: { _ in background + [.chooseForAgents, .choosePersonalMac, .back, .tryAgain] },
                   step: { $0.after($1) }, isExit: { [.ready, .forAgents, .noSecureEnclave].contains($0) },
                   violation: { state, event, next in
            let choosing = [.askHowUsed, .forAgents, .noSecureEnclave].contains(state)
            return choosing && background.contains(event) && next != state ? "Background key work changed the setup choice" : nil
        })
    }

    private struct ImportState: Equatable {
        var session = SelectiveImportSession()
        var priorSession: UUID = StateSpaceVerificationTests.ids[0]
        var priorAttempt: UUID = StateSpaceVerificationTests.ids[1]

        // UUIDs are opaque. Every edge supplies the current ID or a real
        // superseded ID, so changing which UUIDs were allocated adds no state.
        static func == (left: Self, right: Self) -> Bool {
            left.session.phase == right.session.phase && left.session.path == right.session.path
                && left.session.selectedCategories == right.session.selectedCategories
                && left.session.problem == right.session.problem
        }

        var bucket: Int {
            var hash = Hasher()
            hash.combine(session.path)
            hash.combine(session.selectedCategories)
            hash.combine(session.problem)
            hash.combine(session.exportState)
            hash.combine(session.guideStep)
            hash.combine(session.staged?.overrides)
            hash.combine(session.staged?.sortingRemainingCount)
            return hash.finalize()
        }
    }

    private enum ImportAction {
        case tap(SelectiveImportEvent)
        case exportTimeout(stale: Bool)
        case exportStarted(stale: Bool), exportFailed(stale: Bool), exportReady(stale: Bool)
        case sortStarted(stale: Bool)
        case sorted(stale: Bool)
        case sortFinished(stale: Bool)
        case saveFinished(stale: Bool)
        case manualSaveFinished(stale: Bool)
        case saveFailed(stale: Bool)

        var stale: Bool {
            switch self {
            case .tap: false
            case let .exportTimeout(stale), let .exportStarted(stale), let .exportFailed(stale), let .exportReady(stale),
                 let .sortStarted(stale), let .sorted(stale),
                 let .sortFinished(stale), let .saveFinished(stale), let .manualSaveFinished(stale), let .saveFailed(stale): stale
            }
        }

        var isSorting: Bool {
            switch self {
            case .sortStarted, .sorted, .sortFinished: true
            case .tap, .exportTimeout, .exportStarted, .exportFailed, .exportReady, .saveFinished, .manualSaveFinished, .saveFailed: false
            }
        }

        func advances(_ session: SelectiveImportSession) -> Bool {
            guard !stale else { return false }
            switch (session.phase, self) {
            case (_, .tap(.openFlow)), (_, .tap(.closeFlow)), (_, .tap(.reset)):
                return false
            case (.saving, .saveFinished), (.manualSaving, .manualSaveFinished),
                 (.saving, .saveFailed), (.manualSaving, .saveFailed):
                return true
            case (.saving, _), (.manualSaving, _):
                return false
            default:
                switch session.exportState {
                case .waiting, .copying:
                    switch self {
                    case .exportStarted, .exportTimeout, .exportReady, .exportFailed: return true
                    default: return false
                    }
                case .idle, .noneArrived, .allowExport: return true
                }
            }
        }
    }

    @Test func selectiveImport() throws {
        let (normalID, sensitiveID) = (Self.ids[0], Self.ids[1])
        let batch = exportBatch([item(normalID, "github.com"), item(sensitiveID, "my.1password.com")], scope: .selected)
        let receipt = ImportReceipt(filteredCount: 2, savedCount: 1, notSavedCount: 1, savedSites: [])
        let taps: [SelectiveImportEvent] = [
            .openFlow, .closeFlow, .reset, .addMorePasswords, .continueFromChoose, .setGuideStep(5),
            .toggleCategory(.codingCloud), .continueFromCategories, .switchToAllPasswords, .switchToCategories,
            .switchToPickFew, .backToChoose, .backToCategories, .openChangeCategories, .beginExportWaiting,
            .openAllowExport, .closeAllowExport, .clearProblem, .toggleItem(normalID), .toggleItem(sensitiveID),
            .includeAllSensitive, .excludeAllSensitive, .beginSave, .beginManualSave, .showManualReceipt(receipt),
        ] + ImportPath.allCases.map(SelectiveImportEvent.selectPath)
        let events = taps.map(ImportAction.tap) + [false, true].flatMap { stale in
            [ImportAction.exportTimeout(stale: stale), .exportStarted(stale: stale), .exportFailed(stale: stale),
             .exportReady(stale: stale), .sortStarted(stale: stale), .sorted(stale: stale),
             .sortFinished(stale: stale), .saveFinished(stale: stale),
             .manualSaveFinished(stale: stale), .saveFailed(stale: stale)]
        }

        try verify(from: ImportState(), bucket: { $0.bucket }, events: { _ in events }, step: { before, action in
            var next = before
            let sessionID = action.stale ? before.priorSession : before.session.id
            let attemptID = action.stale ? before.priorAttempt : before.session.exportAttemptID
            let event: SelectiveImportEvent = switch action {
            case let .tap(event): event
            case .exportTimeout: .exportTimedOut(attemptID: attemptID)
            case .exportStarted: .beginImporting(sessionID: sessionID)
            case .exportFailed: .failExport(action.stale ? "Late failure" : nil, sessionID: sessionID)
            case .exportReady: .stageIncoming(batch, sessionID: sessionID)
            case .sortStarted: .beginOnDeviceSorting(count: 1, sessionID: sessionID)
            case .sorted: .applyOnDeviceCategory(.codingCloud, ids: [normalID], sessionID: sessionID)
            case .sortFinished: .finishOnDeviceSorting(sessionID: sessionID)
            case .saveFinished: .finishSave(receipt, sessionID: sessionID)
            case .manualSaveFinished: .finishManualSave(nil, sessionID: sessionID)
            case .saveFailed: .failSave(sessionID: sessionID)
            }
            next.session.sendSelectiveImportEvent(event)
            if before.session.id != next.session.id { next.priorSession = before.session.id }
            if before.session.exportAttemptID != next.session.exportAttemptID { next.priorAttempt = before.session.exportAttemptID }
            return next
        }, isExit: { state in
            switch state.session.phase {
            case .closed, .receipt: true
            default: false
            }
        }, isProgress: { state, event in
            event.advances(state.session)
        }, violation: { before, event, next in
            if (event.stale || (before.session.isSaving && event.isSorting)), next.session != before.session {
                return "A late callback changed the current import"
            }
            if let staged = next.session.staged,
               staged.preset != .allReceived, // Pick a Few was already an explicit selection in Passwords.
               staged.items.contains(where: { $0.id == sensitiveID && staged.isSelected($0) }),
               before.session.staged?.selectedIDs.contains(sensitiveID) != true {
                switch event {
                case .tap(.includeAllSensitive), .tap(.toggleItem(sensitiveID)): break
                default: return "A sensitive password was selected without consent"
                }
            }
            return nil
        })
    }

    @Test func requestLifecycle() throws {
        typealias LeaseState = Agentkeyring_V2_LeaseState
        enum Event { case outcome(LeaseState), clock(Int64) }
        let terminal: [LeaseState] = [.denied, .unanswered, .ended, .cancelled, .expired, .released]
        let events = (LeaseState.allCases + [.UNRECOGNIZED(999)]).map(Event.outcome) + [9, 10, 11, 20, 21].map(Event.clock)
        let start = Agentkeyring_V2_Lease.with {
            $0.state = .waiting
            $0.answerByUnixSeconds = 10
            $0.notAfterUnixSeconds = 20
        }
        try verify(from: start, events: { _ in events }, step: { lease, event in
            var next = lease
            switch event {
            case let .outcome(state):
                if CredentialRequestLifecycle.canTransition(from: lease.state, to: state) { next.state = state }
            case let .clock(seconds):
                let now = Date(timeIntervalSince1970: Double(seconds))
                next.state = CredentialRequestLifecycle.effectiveState(of: lease, now: now)
            }
            return next
        }, isExit: { terminal.contains($0.state) }, violation: { lease, _, next in
            terminal.contains(lease.state) && next.state != lease.state ? "A settled request changed outcome" : nil
        })
    }

    private func item(_ id: UUID, _ host: String) -> StoredVaultLogin {
        StoredVaultLogin(id: id, sourceIdentity: LoginSourceIdentity(exporterIdentifier: "test", accountID: Data([1]),
                   itemID: Data(host.utf8)), title: host, origins: ["https://\(host)"],
                   credentials: [.password(userName: "agent", password: "example")])
    }

    @Test func watchDeliveryOrders() throws {
        enum DeliveredCredentialEnvelope: CaseIterable, Hashable {
            case reset, olderContext, newerContext, oldContext
            case oldCatalogue, oldCopies, newCatalogue, newCopies, restart
        }
        func documents(revision: UInt64) throws -> (members: Data, catalogue: Data) {
            let signing = P256.Signing.PrivateKey()
            let phone = Agentkeyring_V2_Device.with {
                $0.signingPublicKey = signing.publicKey.x963Representation
                $0.keyID = CredentialSealing.keyID($0.signingPublicKey)
                $0.noticePublicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
                $0.kind = .iphone
            }
            func sign(_ bytes: Data) throws -> Data {
                try CredentialSealing.signedDocument(bytes, by: phone.keyID) { try signing.signature(for: $0).derRepresentation }.serializedData()
            }
            let members = Members.with {
                $0.domain = "agentkeyring.members.v2"
                $0.revision = revision
                $0.devices = [phone, Agentkeyring_V2_Device.with { $0.keyID = "watch"; $0.kind = .watch }]
            }
            let catalogue = Catalogue.with {
                $0.domain = "agentkeyring.catalogue.v2"
                $0.revision = revision
            }
            return try (sign(members.serializedData()), sign(catalogue.serializedData()))
        }
        func context(resetAt: Double, sentAt: Double, quietFrom: Int32) -> Agentkeyring_V2_PhoneToWatch {
            .with {
                $0.resetAtUnixSeconds = resetAt
                $0.sentAtUnixSeconds = sentAt
                $0.settings.quietHours = true
                $0.settings.quietFromMinutes = quietFrom
            }
        }
        func file(kind: Agentkeyring_V2_WatchFileMetadata.Kind, resetAt: Double, members: Data, bytes: Data) throws
            -> Agentkeyring_V2_PhoneToWatch
        {
            let metadata = Agentkeyring_V2_WatchFileMetadata.with { $0.kind = kind; $0.members = members }
            guard let delivery = WatchStateCoordinator.FileDelivery(bytes, metadata: metadata, resetAt: resetAt) else {
                throw CocoaError(.coderInvalidValue, userInfo: [NSDebugDescriptionErrorKey: "Invalid Watch file fixture"])
            }
            return delivery.message
        }
        let old = try documents(revision: 9)
        let fresh = try documents(revision: 1)
        let copies = try Agentkeyring_V2_WatchCopies.with { $0.generation = 1 }.serializedData()
        let messages: [DeliveredCredentialEnvelope: Agentkeyring_V2_PhoneToWatch] = try [
            .oldContext: context(resetAt: 0, sentAt: 99, quietFrom: 10),
            .reset: context(resetAt: 100, sentAt: 101, quietFrom: 20),
            .olderContext: context(resetAt: 100, sentAt: 102, quietFrom: 30),
            .newerContext: context(resetAt: 100, sentAt: 103, quietFrom: 40),
            .oldCatalogue: file(kind: .catalogue, resetAt: 0, members: old.members, bytes: old.catalogue),
            .oldCopies: file(kind: .copies, resetAt: 0, members: old.members, bytes: copies),
            .newCatalogue: file(kind: .catalogue, resetAt: 100, members: fresh.members, bytes: fresh.catalogue),
            .newCopies: file(kind: .copies, resetAt: 100, members: fresh.members, bytes: copies),
        ]
        try verify(from: WatchPersistedState(), events: { _ in DeliveredCredentialEnvelope.allCases }, step: { before, event in
            guard let message = messages[event] else {
                return try #require(WatchPersistedState.decodeProtobuf(before.encodeProtobuf()))
            }
            let current = event == .olderContext || event == .newerContext
            let update = WatchStateCoordinator.merge(message, into: before, current: current, keyID: "watch",
                                                     now: Date(timeIntervalSince1970: 104))
            if message.resetAtUnixSeconds < (before.lastResetAt ?? 0) {
                #expect(update == nil, "Pre-reset \(event) was eligible for file or context effects")
            }
            return update?.saved ?? before
        }, isExit: { $0.catalogue == fresh.catalogue && $0.settings?.quietFrom == 40 }, violation: { before, event, next in
            guard let message = messages[event] else { return next == before ? nil : "Restart changed Watch state" }
            let floor = before.lastResetAt ?? 0
            if message.resetAtUnixSeconds < floor {
                return next == before ? nil : "A pre-reset delivery changed Watch state"
            }
            let startsGeneration = message.resetAtUnixSeconds > floor
            let takesSettings = message.hasSentAtUnixSeconds && (startsGeneration || message.sentAtUnixSeconds >= (before.lastContextSentAt ?? 0))
            let quietFrom = takesSettings ? Int(message.settings.quietFromMinutes) : startsGeneration ? nil : before.settings?.quietFrom
            if next.settings?.quietFrom != quietFrom { return "Watch notification settings did not follow context ordering" }
            if startsGeneration, next.lastResetAt != message.resetAtUnixSeconds { return "Reset floor was lost" }
            let members = message.hasMembers ? message.members : startsGeneration ? nil : before.members
            if next.members != members { return "Watch trusted the wrong Members" }
            let catalogue = message.hasCatalogue ? message.catalogue : startsGeneration ? nil : before.catalogue
            return next.catalogue == catalogue ? nil : "Watch accepted the wrong Catalogue"
        })
    }

    private struct CopiesState: Equatable {
        var catalogue: UInt64 = 0
        var active: Agentkeyring_V2_WatchCopies?
        var pending: Agentkeyring_V2_WatchCopies?
        var failedWrite = false
    }

    @Test func watchCopies() throws {
        enum Event { case copies(generation: UInt64, requires: UInt64), catalogue(UInt64), failActiveWrite(UInt64) }
        let versions: [UInt64] = [1, 2, 3]
        let deliveries = versions.flatMap { generation in versions.map { Event.copies(generation: generation, requires: $0) } }
            + versions.map(Event.catalogue)
        let fs = FileManager.default
        let directory = fs.temporaryDirectory.appending(path: UUID().uuidString)
        try fs.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fs.removeItem(at: directory) }
        let active = directory.appending(path: "active.pb")
        let store = WatchCopiesStore(file: active)
        var disk = CopiesState()

        func restore(_ copies: Agentkeyring_V2_WatchCopies?, at file: URL) throws {
            if let copies {
                try copies.serializedData().write(to: file)
            } else {
                try fs.removeItem(at: file)
            }
        }

        try verify(from: CopiesState(), events: { state in
            // An occupied directory makes the production atomic replacement fail.
            if state.active == nil, let pending = state.pending {
                return deliveries + versions.filter { $0 >= pending.catalogueRevision }.map(Event.failActiveWrite)
            }
            return deliveries
        }, step: { before, event in
            if disk.active != before.active { try restore(before.active, at: active) }
            if disk.pending != before.pending { try restore(before.pending, at: store.pendingFile) }
            var next = before
            switch event {
            case let .copies(generation, revision):
                let batch = Agentkeyring_V2_WatchCopies.with {
                    $0.generation = generation
                    $0.catalogueRevision = revision
                }
                let catalogue = Catalogue.with { $0.revision = before.catalogue }
                next.failedWrite = store.stageOrReplace(with: batch, catalogue: catalogue) == .writeFailed
            case let .catalogue(revision):
                next.catalogue = max(before.catalogue, revision)
                store.applyPendingIfReady(catalogue: Catalogue.with { $0.revision = next.catalogue })
                next.failedWrite = false
            case let .failActiveWrite(revision):
                next.catalogue = max(before.catalogue, revision)
                try fs.createDirectory(at: active, withIntermediateDirectories: false)
                try Data([0]).write(to: active.appending(path: "occupant"))
                let catalogue = Catalogue.with { $0.revision = next.catalogue }
                next.failedWrite = store.applyPendingIfReady(catalogue: catalogue) == nil
                try fs.removeItem(at: active)
            }
            let held = store.readWatchCopies()
            next.active = held.generation == 0 ? nil : held
            next.pending = fs.fileExists(atPath: store.pendingFile.path)
                ? try Agentkeyring_V2_WatchCopies(serializedBytes: Data(contentsOf: store.pendingFile)) : nil
            disk = next
            return next
        }, isExit: { $0.pending == nil && $0.active?.generation == versions.last }, violation: { before, event, next in
            if case .failActiveWrite = event, !next.failedWrite { return "Expected the atomic write to fail" }
            if next.failedWrite, next.pending != before.pending || next.active != before.active {
                return "A failed write changed active or staged copies"
            }
            let active = next.active?.generation ?? 0
            if active < (before.active?.generation ?? 0) { return "Active copies rolled back" }
            if let pending = before.pending, active < pending.generation,
               (next.pending?.generation ?? 0) < pending.generation {
                return "A newer staged generation was lost"
            }
            return nil
        })
    }

    @Test func vaultDeliveryOrders() throws {
        let id = Self.ids[0]
        let firstEdit = Date(timeIntervalSince1970: 10)
        let lastEdit = Date(timeIntervalSince1970: 11)
        let gone = Date(timeIntervalSince1970: 12)
        let source = item(id, "example.test").sourceIdentity
        let original = StoredVaultLogin(id: id, sourceIdentity: source, lastModifiedAt: firstEdit, title: "Example", origins: ["https://example.test"],
                                  credentials: [], imports: [LoginSecretRevisionStamp(revision: firstEdit, version: 1, actor: "Mac", exportedAt: firstEdit)])
        let changed = StoredVaultLogin(id: id, sourceIdentity: source, lastModifiedAt: lastEdit, title: "Edited", origins: ["https://example.test"],
                                 credentials: [], imports: [LoginSecretRevisionStamp(revision: lastEdit, version: 2, actor: "iPhone", exportedAt: lastEdit)])
        let blocked = CredentialVault(items: [id: original], rules: [id: LoginRuleTimestampEntry(.blocked, updatedAtMs: 12_000, actor: "Mac")])
            .deletingBlockedSecrets(at: 3)
        let edit = CredentialVault(items: [id: changed])
        let deletion = CredentialVault(deleted: [id: gone])
        let peers = ["Block": blocked, "Edit": edit, "Delete": deletion]
        let reference = CredentialVaultMerge.mergeVaults(CredentialVaultMerge.mergeVaults(blocked, edit), deletion)
        struct DeliveredCredentialEnvelope: Equatable {
            var vault = CredentialVault()
            var seen: Set<String> = []
        }
        // Repeated delivery gives idempotence, and every prefix is checked
        // before examining longer orderings.
        try verify(from: DeliveredCredentialEnvelope(), events: { _ in ["Block", "Edit", "Delete"] }, step: { state, event in
            var next = state
            if let peer = peers[event] { next.vault = CredentialVaultMerge.mergeVaults(state.vault, peer) }
            next.seen.insert(event)
            return next
        }, isExit: { $0.seen.count == 3 }, violation: { state, event, next in
            if state.seen.contains(event), state != next { return "Re-delivery changed the merged vault" }
            if let peer = peers[event], CredentialVaultMerge.mergeVaults(peer, state.vault) != next.vault {
                return "Reversing the merge changed the vault"
            }
            if next.seen.contains("Block"),
               next.vault.liveSecret(id) != nil || next.vault.items[id]?.secretDeleted != true {
                return "A merge restored a blocked password"
            }
            if next.seen.count == 3, next.vault != reference { return "The three peers did not converge" }
            return nil
        })
        // Compare both groupings for every ordering, even if BFS merged their prefixes.
        for a in peers.keys.sorted() {
            for b in peers.keys.sorted() where b != a {
                let c = peers.keys.first { $0 != a && $0 != b }
                guard let left = peers[a], let middle = peers[b], let c, let right = peers[c] else { continue }
                #expect(CredentialVaultMerge.mergeVaults(left, CredentialVaultMerge.mergeVaults(middle, right)) == reference,
                        "Delivery order: \(a) -> \(b) -> \(c)")
            }
        }
    }

    @Test func cloudDeliveryOrders() throws {
        let signing = P256.Signing.PrivateKey()
        let device = Agentkeyring_V2_Device.with {
            $0.signingPublicKey = signing.publicKey.x963Representation
            $0.keyID = CredentialSealing.keyID($0.signingPublicKey)
            $0.noticePublicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
            $0.kind = .iphone
        }
        func sign(_ data: Data) throws -> SignedDocument {
            try CredentialSealing.signedDocument(data, by: device.keyID) { try signing.signature(for: $0).derRepresentation }
        }
        let lists = (1...4).map { revision in
            Members.with {
                $0.domain = "agentkeyring.members.v2"
                $0.revision = UInt64(revision)
                $0.devices = [device]
            }
        }
        let documents = try lists.map { try sign($0.serializedData()).serializedData() }
        let payloads = try (1...3).map { try CloudMembers.payload(current: documents[$0], history: Array(documents[..<$0])) }
        try verify(from: lists[0], events: { _ in [1, 2, 3] }, step: { held, delivery in
            let history = Array(documents.prefix(Int(held.revision)))
            let next = CloudMembers.followed(payloads[delivery - 1], members: held, history: history)
            if let next, next.revision > held.revision { return next }
            return held
        }, isExit: { $0 == lists[3] }, violation: { held, delivery, next in
            next != lists[max(Int(held.revision) - 1, delivery)] ? "Signed Members did not advance monotonically" : nil
        })

        let registrations = [UInt8(1), 2].map { token in
            Agentkeyring_V2_PushRegistration.with {
                $0.domain = "agentkeyring.push.v2"
                $0.deviceKeyID = device.keyID
                $0.apnsToken = Data([token])
                $0.apnsTopic = "example.test"
                $0.noticePublicKey = device.noticePublicKey
                $0.registeredUnixSeconds = 10
            }
        }
        let signed = try registrations.map { try sign($0.serializedData()).serializedData() }
        func deliver(_ index: Int, to current: Data?) -> Data? {
            CloudPushRegistration.isNewer(registrations[index], than: current) ? signed[index] : current
        }
        let firstOrder = deliver(1, to: deliver(0, to: nil))
        let secondOrder = deliver(0, to: deliver(1, to: nil))
        #expect(firstOrder != nil && firstOrder == secondOrder, "Delivery orders: push(1) -> push(2) and push(2) -> push(1)")
    }
}
