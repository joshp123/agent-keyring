// Written by AI on 2026.11.26 by model gemini-4-neon.
//
// Opens and names a push notice for the iPhone notification service extension
// without pulling in iCloud, credential import or the domain catalogue.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import Foundation
import OSLog

/// A notified request as the Lock Screen shows it.
public struct DecodedPushNotificationRequest {
    public let request: AccessRequest
    public let answeredBy: String?
    public init(request: AccessRequest, answeredBy: String?) {
        self.request = request
        self.answeredBy = answeredBy
    }
}

public struct PushNotificationDecodeError: Error, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}

public enum PhoneNoticeDecoder {
    /// Whether a request arriving now may break through a Focus, from the iPhone's Settings.
    nonisolated public static func breaksThroughFocus(_ shared: PhoneSharedContext) -> Bool {
        (shared.readSnapshot()?.settings ?? NotificationSettings()).breaksThroughFocus()
    }

    /// The request a push is about, as the Lock Screen shows it: the notice opened, the login and computer
    /// named from the saved Catalogue and Members.
    nonisolated public static func notifiedRequest(
        _ userInfo: [AnyHashable: Any],
        shared: PhoneSharedContext,
        open: (Agentkeyring_V2_Notice, String) throws -> Agentkeyring_V2_SignedRequestEnvelope
    ) -> DecodedPushNotificationRequest? {
        let log = Logger(subsystem: "com.joshpalmer.AgentKeyring.Phone", category: "Notice")
        func fail(_ step: String) -> DecodedPushNotificationRequest? {
            log.error("Could not name the request: \(step, privacy: .public)")
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Could not name the request: \(step)"])
            return nil
        }
        guard let base64 = userInfo["akr"] as? String, let bytes = Data(base64Encoded: base64),
              let notice = try? Agentkeyring_V2_Notice(serializedBytes: bytes) else { return fail("no notice in the push") }
        guard let saved = shared.readSnapshot() else { return fail("the shared keychain item is missing") }
        guard let keyID = saved.deviceKeyID else { return fail("no device key id saved") }
        let envelope: Agentkeyring_V2_SignedRequestEnvelope
        do { envelope = try open(notice, keyID) } catch { return fail("the notice did not open: \(error)") }
        guard let members = saved.members.flatMap({ try? SignedDocument(serializedBytes: $0) }).flatMap({ try? Members(serializedBytes: $0.payload) })
        else { return fail("no Members saved") }
        let catalogue = saved.catalogue.flatMap { try? SignedDocument(serializedBytes: $0) }.flatMap { try? Catalogue(serializedBytes: $0.payload) }
        do {
            let named = try named(envelope, members: members, catalogue: catalogue, keyID: keyID)
            return DecodedPushNotificationRequest(request: named.request, answeredBy: named.answeredBy)
        } catch { return fail("\(error)") }
    }

    /// An opened notice's request, named from the signed Members and Catalogue only: this iPhone's own
    /// practice request, or one the computer it names signed.
    nonisolated public static func named(
        _ envelope: Agentkeyring_V2_SignedRequestEnvelope,
        members: Members,
        catalogue: Catalogue?,
        keyID: String
    ) throws -> (request: AccessRequest, answeredBy: String?) {
        guard let request = try? CredentialSealing.parseRequest(envelope.request) else { throw PushNotificationDecodeError(description: "the request did not parse") }
        let outcome = envelope.hasOutcome ? leaseState(envelope.outcome, now: Int64(Date().timeIntervalSince1970), members: members)
            : .waitingForYou(until: Date(timeIntervalSince1970: Double(request.answerByUnixSeconds)))
        // verifySignedLeaseRequest returns no computer for this device's own practice request, and throws for an unsigned one.
        let signer: Agentkeyring_V2_Machine?
        do { signer = try CredentialSealing.verifySignedLeaseRequest(envelope, members: members, ownKeyID: keyID) }
        catch { throw PushNotificationDecodeError(description: "the request is not signed by the computer it names") }
        guard let machine = signer else {
            var practice = practiceRequest(request)
            practice.state = outcome
            return (practice, nil)
        }
        guard let login = catalogue?.logins.first(where: { $0.loginID == request.loginID }) else { throw PushNotificationDecodeError(description: "login not in the saved catalogue") }
        return (AccessRequest(id: request.requestID, login: RequestedLogin(site: site(login), account: login.account),
                              agent: RequestingAgent(name: request.agent, machine: machine.label, address: "",
                                                     project: request.project.isEmpty ? nil : request.project),
                              access: .login, agentReason: request.reason,
                              askedAt: Date(timeIntervalSince1970: Double(request.askedUnixSeconds)), state: outcome),
                envelope.hasOutcome ? members.devices.first { $0.label == envelope.outcome.answeredBy }.flatMap { shortName($0.kind) } : nil)
    }

    /// The practice request in the real request's layout, with the board's words.
    nonisolated public static func practiceRequest(_ request: KeyringRequest) -> AccessRequest {
        .practiceAccessRequest(id: request.requestID, askedAt: Date(timeIntervalSince1970: Double(request.askedUnixSeconds)),
                  until: Date(timeIntervalSince1970: Double(request.answerByUnixSeconds)))
    }

    nonisolated public static func leaseState(_ lease: Agentkeyring_V2_Lease, now: Int64, members: Members? = nil) -> AccessRequestState {
        let notAfter = Date(timeIntervalSince1970: Double(lease.notAfterUnixSeconds))
        let device = members?.devices.first { $0.label == lease.answeredBy }
        let surface: ApprovalSurface = switch device?.kind {
        case .mac?: .mac
        case .watch?: .watch
        default: .iPhone
        }
        switch lease.state {
        case .waiting: return .waitingForYou(until: Date(timeIntervalSince1970: Double(lease.answerByUnixSeconds)))
        case .approved: return lease.notAfterUnixSeconds > now ? .approved(by: surface, until: notAfter) : .expired(at: notAfter)
        case .denied:
            return .denied(by: surface, reply: lease.reply.isEmpty ? nil : lease.reply,
                           askAgainAfter: lease.retryNotBeforeUnixSeconds > 0 ? Date(timeIntervalSince1970: Double(lease.retryNotBeforeUnixSeconds)) : nil)
        case .ended: return .ended(at: notAfter)
        case .expired: return .expired(at: notAfter)
        case .released: return .released(at: Date(timeIntervalSince1970: TimeInterval(lease.endedAtUnixSeconds)))
        case .cancelled: return .cancelled
        case .unanswered, .unspecified, .UNRECOGNIZED: return .unanswered
        }
    }

    nonisolated public static func site(_ login: Agentkeyring_V2_Login) -> String {
        login.sites.first.flatMap { URL(string: $0)?.host ?? $0 } ?? login.title
    }

    /// "Approved on your Watch": the kind of device, as Paper names it.
    nonisolated public static func shortName(_ kind: Agentkeyring_V2_DeviceKind) -> String? {
        switch kind {
        case .iphone: "iPhone"
        case .watch: "Apple Watch"
        case .mac: "Mac"
        default: nil
        }
    }
}
