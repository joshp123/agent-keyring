import AgentKeyringFeature
import Foundation
import Testing
@testable import AgentKeyringCLI

@MainActor
@Suite("Phone approval status lines")
struct PhoneApprovalStatusLinesTests {
    @Test("Locked and escalation paths use exact owner-specific lines", arguments: ["locked", "asleep", "escalation"])
    func statusLines(path: String) async throws {
        try await MacOwner.$fullName.withValue("Josh Example") {
            let locked = path != "escalation"
            let asleep = path == "asleep"
            let start = try #require(Calendar.current.date(from: DateComponents(
                year: 2026, month: 10, day: 12, hour: 2, minute: 41)))
            let phoneAt = locked ? start : start.addingTimeInterval(120)
            let approvedAt = start.addingTimeInterval(180)
            let pipe = Pipe()
            let lines = CLIApprovalStatusLines(diagnostics: pipe.fileHandleForWriting)
            lines.receive(.progress(AgentApprovalProgress(waitingSince: start, phase: .awaitingApproval)))
            if !locked {
                lines.receive(.progress(AgentApprovalProgress(waitingSince: start, askedAt: start,
                    phase: .awaitingApproval, provider: .mac, phoneScheduledAt: phoneAt)))
            }
            let asked = AgentApprovalProgress(waitingSince: start, askedAt: phoneAt,
                phase: .awaitingApproval, provider: .iPhone, macWasLocked: locked, macWasAsleep: asleep)
            lines.receive(.progress(asked))
            lines.receive(.progress(asked))
            let approved = AgentApprovalProgress(waitingSince: start, askedAt: phoneAt,
                phase: .awaitingApproval, provider: .iPhone, macWasLocked: locked, macWasAsleep: asleep,
                approvedAt: approvedAt, approvedOn: .iPhone)
            lines.receive(.progress(approved))
            try await CLIClient.run(.acquire(field: .password, targetURL: "https://example.com",
                account: nil, credentialID: nil), output: FileHandle.nullDevice,
                diagnostics: pipe.fileHandleForWriting, now: { approvedAt.addingTimeInterval(120) },
                sendRequest: { request in AgentBridgeResponse(id: request.id, ok: true, approvalProgress: approved) })
            try pipe.fileHandleForWriting.close()
            let actual = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let expected = asleep ? """
            Josh's Mac is asleep or locked; asked on the iPhone at 02:41.
            Approved on the iPhone at 02:44.

            """ : locked ? """
            Josh's Mac is locked; asked on the iPhone at 02:41.
            Approved on the iPhone at 02:44.

            """ : """
            Asked Josh on the Mac at 02:41; will ask on the iPhone at 02:43.
            Asked Josh on the iPhone at 02:43.
            Approved on the iPhone at 02:44.

            """
            #expect(actual == expected)
            print(actual, terminator: "")
        }
    }

    @Test("CloudKit fallback reasons produce the exact line once", arguments: IPhoneApprovalFailure.allCases)
    func fallbackLine(failure: IPhoneApprovalFailure) throws {
        let reasons: [IPhoneApprovalFailure: String] = [
            .notSignedInToICloud: "not signed in to iCloud", .networkUnavailable: "network unavailable",
            .quotaExceeded: "iCloud quota exceeded", .rateLimited: "iCloud rate-limited", .unavailable: "iCloud unavailable"]
        let pipe = Pipe()
        let lines = CLIApprovalStatusLines(diagnostics: pipe.fileHandleForWriting)
        let progress = AgentApprovalProgress(waitingSince: Date(), phase: .awaitingApproval,
            provider: .mac, iPhoneFailure: failure)
        // The reason survives the bridge's existing Codable transport.
        let decoded = try PropertyListDecoder().decode(AgentApprovalProgress.self,
            from: PropertyListEncoder().encode(progress))
        lines.receive(.progress(decoded))
        lines.receive(.progress(decoded))
        try pipe.fileHandleForWriting.close()
        let actual = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(actual == "The iPhone could not be reached (\(try #require(reasons[failure]))); asking on the Mac only.\n")
        print(actual, terminator: "")
    }

    @Test("A Mac win after phone escalation is reported as a Mac approval")
    func macWinsAfterEscalation() async throws {
        let pipe = Pipe()
        let now = try #require(Calendar.current.date(from: DateComponents(
            year: 2026, month: 10, day: 12, hour: 2, minute: 44)))
        let progress = AgentApprovalProgress(waitingSince: now.addingTimeInterval(-180),
            askedAt: now.addingTimeInterval(-60), phase: .awaitingApproval, provider: .iPhone,
            approvedAt: now, approvedOn: .mac)
        try await CLIClient.run(.acquire(field: .password, targetURL: "https://example.com", account: nil, credentialID: nil),
            output: FileHandle.nullDevice, diagnostics: pipe.fileHandleForWriting, now: { now },
            sendRequest: { request in AgentBridgeResponse(id: request.id, ok: true, approvalProgress: progress) })
        try pipe.fileHandleForWriting.close()
        #expect(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "Approved on the Mac at 02:44.\n")
    }
}
