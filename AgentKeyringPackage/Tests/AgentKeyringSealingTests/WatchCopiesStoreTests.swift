// Written by AI on 2026.11.27 by model gpt-6.2-sol.

import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import Testing

struct WatchCopiesStoreTests {
    @Test("An older Watch transfer leaves a newer staged transfer ready for its catalogue")
    func outOfOrderTransfers() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WatchCopiesStore(file: directory.appending(path: "copies.pb"))
        let newer = transfer(12, requiring: 5)
        let older = transfer(11, requiring: 4)

        #expect(store.stageOrReplace(with: newer, catalogue: catalogue(4)) == .stagedWaitingForCatalogue)
        #expect(store.stageOrReplace(with: older, catalogue: catalogue(4)) == .applied)
        #expect(store.readWatchCopies() == older)
        #expect(store.applyPendingIfReady(catalogue: catalogue(5)) == 12)
        #expect(store.readWatchCopies() == newer)
    }

    @Test("The Watch can apply staged copies after a failed write to the active file")
    func activeFileWriteFailure() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let active = directory.appending(path: "copies.pb")
        let store = WatchCopiesStore(file: active)
        let newer = transfer(12, requiring: 5)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try Data([1]).write(to: active.appending(path: "occupant"))

        #expect(store.stageOrReplace(with: newer, catalogue: catalogue(4)) == .stagedWaitingForCatalogue)
        #expect(store.stageOrReplace(with: transfer(11, requiring: 4), catalogue: catalogue(4)) == .writeFailed)
        #expect(store.applyPendingIfReady(catalogue: catalogue(5)) == nil)
        try FileManager.default.removeItem(at: active)

        let reopened = WatchCopiesStore(file: active)
        #expect(reopened.applyPendingIfReady(catalogue: catalogue(5)) == 12)
        #expect(reopened.readWatchCopies() == newer)
    }

    private func transfer(_ generation: UInt64, requiring revision: UInt64) -> Agentkeyring_V2_WatchCopies {
        var copies = Agentkeyring_V2_WatchCopies()
        copies.generation = generation
        copies.catalogueRevision = revision
        var copy = SealedLogin()
        copy.loginID = "example"
        copy.version = revision
        copies.copies = [copy]
        return copies
    }

    private func catalogue(_ revision: UInt64) -> Catalogue {
        var catalogue = Catalogue()
        catalogue.revision = revision
        var login = Agentkeyring_V2_Login()
        login.loginID = "example"
        login.rule = .ask
        login.version = revision
        catalogue.logins = [login]
        return catalogue
    }
}
