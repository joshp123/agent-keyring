import AgentKeyringTestSupport
import Darwin
import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Harness attribution")
struct AgentRequesterAttributionTests {
    @Test("The socket peer's ancestry supplies the harness, session and folder", arguments: ["claude", "codex"])
    func harnessAncestor(executable: String) throws {
        let tree: [pid_t: (executablePath: String, parentPID: pid_t)] = [
            100: ("/opt/bin/agent-keyring", 101), 101: ("/bin/zsh", 102),
            102: ("/usr/bin/python3", 103), 103: ("/opt/bin/\(executable)", 1),
        ]
        let start = HarnessProcessStartTime(seconds: 1_000, microseconds: 123)
        let requester = AgentRequester.attribution(peerProcessIdentifier: 100, processInfo: { tree[$0] },
            startTime: { pid in #expect(pid == 103); return start },
            folder: { pid in #expect(pid == 103); return "/fixture/project" })
        #expect(requester.name == (executable == "claude" ? "Claude Code" : "Codex"))
        #expect(requester.displayLabel == requester.name)
        #expect(requester.session == HarnessSession(processIdentifier: 103, processStartTime: start))
        #expect(requester.workingDirectory == "/fixture/project")
    }

    @Test("A process that changes during attribution cannot receive a reusable session grant")
    func unstableProcess() {
        var reads = 0
        let requester = AgentRequester.attribution(peerProcessIdentifier: 100,
            processInfo: { _ in ("/opt/bin/claude", 1) }, startTime: { _ in
                reads += 1
                return HarnessProcessStartTime(seconds: UInt64(reads), microseconds: 0)
            }, folder: { _ in "/fixture" })
        #expect(requester.session == nil)
    }

    @Test("Phone records contain signed harness attribution, with host details only in activity", arguments: ["pid", "seconds", "microseconds", "folder"])
    func signedAttribution(changedField: String) throws {
        let request = try ApprovalRequest(agentDisplayLabel: syntheticRequester.displayLabel, site: "example.com",
            account: "fixture", field: .password, action: .fill, requesterContext: syntheticRequester.approvalContext)
        let record = ApprovalCloudRecords.request(request)
        let fields = try #require(ApprovalCloudRecords.signedFields(from: record))
        #expect(fields == request.signedFields)
        #expect(fields.notificationTitle.contains("Fixture agent"))
        #expect(fields.notificationBody.contains("/tmp"))
        #expect(!fields.notificationBody.contains(syntheticRequester.machineName))
        #expect(!fields.notificationBody.contains(syntheticRequester.networkAddress!))
        #expect(record.encryptedValues["machineName"] == nil && record.encryptedValues["networkAddress"] == nil)
        let session = try #require(syntheticRequester.session)
        let changedSession = HarnessSession(processIdentifier: session.processIdentifier + (changedField == "pid" ? 1 : 0),
            processStartTime: HarnessProcessStartTime(seconds: session.processStartTime.seconds + (changedField == "seconds" ? 1 : 0),
                microseconds: session.processStartTime.microseconds + (changedField == "microseconds" ? 1 : 0)))
        let changed = ApprovalSignedFields(requestID: fields.requestID, agentDisplayLabel: fields.agentDisplayLabel,
            site: fields.site, account: fields.account, field: fields.field, action: fields.action,
            oneTimeValue: fields.oneTimeValue, expiresAt: fields.expiresAt,
            requesterContext: ApprovalRequesterContext(session: changedSession,
                workingDirectory: changedField == "folder" ? "/elsewhere" : "/tmp"))
        #expect(fields.canonicalBytes(for: .approve) != changed.canonicalBytes(for: .approve))
        let activity = AgentRequestActivity(requestID: request.id, action: .fill, requester: syntheticRequester,
            completedAt: Date(), succeeded: true, error: nil)
        #expect(activity.requester.machineName == "Fixture Mac")
        #expect(activity.requester.networkAddress == "192.0.2.1")
    }
}
