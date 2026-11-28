// Written by AI on 2026.11.28 by model claude opus 5.5.
//
// A Mac's push to iCloud and its removal of a device, through the shared replica (AgentKeyringEngine/Cloud): a
// device removed while the push waits is sealed nothing written after, iCloud keeping another device's
// revision is a conflict whatever the Mac managed to save, a removal after signing back in goes to iCloud, and a
// removal the Mac cannot save fails with the device still listed.

@testable import AgentKeyringEngine
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import LocalAuthentication
import Testing

/// An InMemoryCloudPipe that runs `duringCatalogueWrite` once while the shared catalogue is being written, and
/// keeps every record a device wrote of its own.
private final class PausingCloudPipe: CloudPipe, @unchecked Sendable {
    let inner = InMemoryCloudPipe()
    var duringCatalogueWrite: (@MainActor () async -> Void)?
    var ownRecordsWritten: [CloudRecord] = []

    func availability() async -> CloudAvailability { await inner.availability() }
    func fetchCloudChanges(since token: Data?) async throws -> CloudChanges { try await inner.fetchCloudChanges(since: token) }
    func fetchCloudRecord(named name: String) async throws -> CloudRecord? { try await inner.fetchCloudRecord(named: name) }
    func writeCloudRecords(_ records: [CloudRecord]) async throws {
        ownRecordsWritten += records
        try await inner.writeCloudRecords(records)
    }
    func deleteCloudRecords(_ names: [String]) async throws { try await inner.deleteCloudRecords(names) }
    func writeCloudRecordIfNewer(_ record: CloudRecord, isNewer: @escaping @Sendable (Data) -> Bool) async throws -> Data? {
        if record.name == CloudRecordKind.catalogue, let pause = duringCatalogueWrite {
            duringCatalogueWrite = nil
            await pause()
        }
        return try await inner.writeCloudRecordIfNewer(record, isNewer: isNewer)
    }
    func putMembersAndCatalogueAtomically(members: CloudRecord, mayReplaceMembers: @escaping @Sendable (Data) -> Bool,
                                          catalogue: CloudRecord, mayReplaceCatalogue: @escaping @Sendable (Data) -> Bool)
        async throws -> CloudAtomicOutcome {
        try await inner.putMembersAndCatalogueAtomically(members: members, mayReplaceMembers: mayReplaceMembers,
                                                         catalogue: catalogue, mayReplaceCatalogue: mayReplaceCatalogue)
    }
    func deleteCloudZone() async throws { try await inner.deleteCloudZone() }
    func forgetLocalCloudState() {}
}


extension ReplicaCoreTests {
    /// Members at `revision` listing `devices`, signed by the Mac.
    private func members(_ revision: UInt64, _ devices: [Agentkeyring_V2_Device], by keys: MacKeys) throws -> Data {
        var members = Members()
        members.domain = "agentkeyring.members.v2"
        members.revision = revision
        members.devices = devices
        return try CredentialSealing.signedDocument(members.serializedData(), by: keys.deviceKeyID) {
            try keys.signWithDeviceKey($0, context: LAContext())
        }.serializedData()
    }

    @Test("The iPhone removed while the Mac writes the catalogue is sealed nothing the Mac writes after")
    func removalDuringPushSealsNothingToTheRemovedDevice() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Test Mac")
        let phone = Peer(kind: .iphone)
        let pipe = PausingCloudPipe()
        let device = mac(keys, Store(), pipe, in: folder)
        defer { device.stopBackgroundWork() }
        #expect(await device.receiveSignedMembers(try members(1, [keys.device, phone.device], by: keys)) == .taken)
        #expect(await device.receiveSignedCatalogue(try signed(catalogue(1, []), by: keys)) == .taken)
        var mailbox = Agentkeyring_V2_UpdateMailbox()
        mailbox.machineID = "build-box"
        mailbox.seed = Data(repeating: 1, count: 32)
        mailbox.readAuth = "read"
        mailbox.writeAuth = "write"
        try device.cloudSync.mailboxes.keepComputerMailbox(mailbox)

        let withoutPhone = try members(2, [keys.device], by: keys)
        pipe.duringCatalogueWrite = { #expect(await device.receiveSignedMembers(withoutPhone) == .taken) }
        await device.cloudSync.pushCloudNow()
        #expect(device.members?.devices.contains { $0.keyID == phone.id } == false)
        await device.cloudSync.pushCloudNow()

        #expect(pipe.ownRecordsWritten.contains { $0.name == CloudRecordKind.mailbox("build-box") })
        for record in pipe.ownRecordsWritten {
            #expect(CloudEnvelope.openCloudEnvelope(record.payload, expectedKind: record.kind, deviceID: phone.id, opener: phone.opener) == nil,
                    "\(record.name) opens for the removed iPhone")
        }
    }

    @Test("iCloud keeping the iPhone's revision of Members is a conflict, even when the Mac cannot save that it saw it")
    func cloudMembersConflictWithFailedSave() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Test Mac")
        let phone = Peer(kind: .iphone)
        let pipe = InMemoryCloudPipe()
        let store = Store()
        let device = mac(keys, store, pipe, in: folder)
        defer { device.stopBackgroundWork() }
        let first = try members(1, [keys.device, phone.device], by: keys)
        #expect(await device.receiveSignedMembers(first) == .taken)
        #expect(await device.cloudSync.confirmCloudMembers() == .owned)
        #expect(device.saved.cloudAcceptedMembers == first)

        // Apart, each signs revision 2: the iPhone's reaches iCloud first.
        var renamed = phone.device
        renamed.label = "Josh's iPhone"
        var phoneSide = Members()
        phoneSide.domain = "agentkeyring.members.v2"
        phoneSide.revision = 2
        phoneSide.devices = [keys.device, renamed]
        let phoneSigned = try phone.signed(phoneSide.serializedData())
        try await pipe.writeCloudRecords([CloudRecord(kind: CloudRecordKind.members, writer: phone.id,
                                                      payload: try CloudMembers.payload(current: phoneSigned, history: [first]))])
        var renamedMac = keys.device
        renamedMac.label = "Renamed Mac"
        #expect(await device.receiveSignedMembers(try members(2, [renamedMac, phone.device], by: keys)) == .taken)

        store.failWrites = true
        #expect(await device.cloudSync.confirmCloudMembers() == .conflict)
    }

    @Test("Signed back in to iCloud since the last pull, a removal goes to iCloud, never only to this Mac")
    func removalAfterSigningBackIn() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Test Mac")
        let phone = Peer(kind: .iphone)
        let pipe = InMemoryCloudPipe()
        let device = mac(keys, Store(), pipe, in: folder)
        defer { device.stopBackgroundWork() }
        #expect(await device.receiveSignedMembers(try members(1, [keys.device, phone.device], by: keys)) == .taken)
        pipe.setAvailability(.signedOut)
        #expect(!(await device.cloudSync.pullCloudNow()))
        #expect(device.cloudSync.state == .signedOut)
        pipe.setAvailability(.available)

        try await device.cloudSync.removeDeviceAtomically(phone.id) { try keys.signWithDeviceKey($0, context: LAContext()) }

        let inCloud = try #require(pipe.records[CloudRecordKind.members])
        let newest = try #require(CloudMembers.revisions(inCloud.payload).last)
        let listed = try Members(serializedBytes: newest.payload)
        #expect(listed.revision == 2 && !listed.devices.contains { $0.keyID == phone.id })
    }

    @Test("A removal the Mac cannot save fails, and the device stays listed")
    func removalNotSavedFails() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys = MacKeys(testing: try DeviceTLSIdentity.ephemeral(), label: "Test Mac")
        let phone = Peer(kind: .iphone)
        let store = Store()
        let device = mac(keys, store, nil, in: folder)
        defer { device.stopBackgroundWork() }
        let first = try members(1, [keys.device, phone.device], by: keys)
        #expect(await device.receiveSignedMembers(first) == .taken)

        store.failWrites = true
        await #expect(throws: (any Error).self) {
            try await device.cloudSync.removeDeviceAtomically(phone.id) { try keys.signWithDeviceKey($0, context: LAContext()) }
        }
        #expect(device.members?.devices.contains { $0.keyID == phone.id } == true)
        #expect(device.saved.members == first)
    }
}
