// Written by AI on 2026.11.21 by model claude opus 5.5; shared with the
// iPhone, and through /v1/push, on 2026.11.24.
//
// Pushes to the user's devices, sent by a Mac or an iPhone: through the push
// relay (https://push.opentrawl.sh, POST /v1/push with the device's address
// in x-akr-token, never the URL), or straight to Apple with the team's push key
// (PushCredential) and an ES256 token. The payloads are exactly those in
// keyring.proto, "The push".

import AgentKeyringProtocol
import CryptoKit
import Foundation
import Synchronization

/// Trusts a stand-in for Apple's service only by its exact key, in tests. Apple's own is checked as any public site is.
private final class StandInPin: NSObject, URLSessionDelegate, Sendable {
    let spki: Data
    init(spki: Data) { self.spki = spki }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
            (try? DeviceTLSIdentity.spki(certificate: leaf)) == spki else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// Where pushes go: Apple's two services, or a stand-in pinned to its key in tests.
public struct ApplePushGateway: Sendable {
    public let production: URL
    public let sandbox: URL
    public let pin: Data?
    public init(production: URL, sandbox: URL, pin: Data?) {
        self.production = production
        self.sandbox = sandbox
        self.pin = pin
    }
    public static let apple = ApplePushGateway(production: URL(string: "https://api.push.apple.com")!,
        sandbox: URL(string: "https://api.sandbox.push.apple.com")!, pin: nil)
}

public struct ApplePushError: Error, CustomStringConvertible {
    public let status: Int
    public let reason: String
    /// Apple says this push address is no longer the device's: forget it.
    public var invalidToken: Bool { status == 410 || reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic" }
    public var description: String { "Apple refused the push: \(status) \(reason)" }
}

public final class ApplePush: Sendable {
    /// Default stateless blind APNs push-signing relay for users without their own Apple Developer .p8 key.
    public static let defaultRelayURL = URL(string: "https://push.opentrawl.sh")!

    private enum Mode: Sendable {
        case direct(credential: Agentkeyring_V2_PushCredential, key: P256.Signing.PrivateKey)
        case relay(URL)
    }

    private let mode: Mode
    /// Present only when this Mac holds a local Apple Developer .p8 key (direct APNs mode).
    public var credential: Agentkeyring_V2_PushCredential? {
        if case let .direct(credential, _) = mode { return credential }
        return nil
    }
    private let gateway: ApplePushGateway
    private let session: URLSession
    private let ownsSession: Bool
    private let token = Mutex<(text: String, issued: Date)?>(nil)

    public init(credential: Agentkeyring_V2_PushCredential, gateway: ApplePushGateway = .apple) throws {
        let key = try P256.Signing.PrivateKey(derRepresentation: credential.privateKey)
        self.mode = .direct(credential: credential, key: key)
        self.gateway = gateway
        session = URLSession(configuration: .ephemeral, delegate: gateway.pin.map { StandInPin(spki: $0) }, delegateQueue: nil)
        ownsSession = true
    }

    /// Sends encrypted push payloads via a stateless blind APNs relay (such as https://push.opentrawl.sh).
    public init(relayURL: URL = ApplePush.defaultRelayURL, gateway: ApplePushGateway = .apple, session: URLSession? = nil) {
        self.mode = .relay(relayURL)
        self.gateway = gateway
        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            self.session = URLSession(configuration: .ephemeral, delegate: gateway.pin.map { StandInPin(spki: $0) }, delegateQueue: nil)
            self.ownsSession = true
        }
    }

    deinit { if ownsSession { session.finishTasksAndInvalidate() } }

    /// Apple's provider token: signed once, kept 30 minutes (Apple takes one up to an hour old).
    func authorization(now: Date = .now) throws -> String {
        guard case let .direct(credential, key) = mode else { return "" }
        return try token.withLock { current in
            if let current, now.timeIntervalSince(current.issued) < 1800 { return current.text }
            func part(_ object: [String: Any]) throws -> String {
                try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).base64URLEncoded
            }
            let unsigned = try part(["alg": "ES256", "kid": credential.keyID]) + "." + part(["iss": credential.teamID, "iat": Int(now.timeIntervalSince1970)])
            let text = unsigned + "." + (try key.signature(for: Data(unsigned.utf8))).rawRepresentation.base64URLEncoded
            current = (text, now)
            return text
        }
    }

    /// One push to one device: `visible`, an alert the user sees and hears; otherwise a silent background push.
    public func sendPush(_ payload: Data, to registration: Agentkeyring_V2_PushRegistration, collapseID: String, expiration: Int64,
        visible: Bool) async throws {
        let base: URL
        switch mode {
        case .direct:
            base = registration.apnsProduction ? gateway.production : gateway.sandbox
        case let .relay(relayURL):
            base = relayURL
        }
        let token = registration.apnsToken.map { String(format: "%02x", $0) }.joined()
        var request: URLRequest
        switch mode {
        case .direct:
            request = URLRequest(url: base.appending(path: "3/device/" + token), timeoutInterval: 10)
            request.setValue("bearer " + (try authorization()), forHTTPHeaderField: "authorization")
        case .relay:
            // The address in a header, never the URL, so nothing that logs URLs sees it.
            request = URLRequest(url: base.appending(path: "v1/push"), timeoutInterval: 10)
            request.setValue(token, forHTTPHeaderField: "x-akr-token")
            request.setValue(registration.apnsProduction ? "production" : "sandbox", forHTTPHeaderField: "x-apns-env")
        }
        request.httpMethod = "POST"
        request.setValue(registration.apnsTopic, forHTTPHeaderField: "apns-topic")
        request.setValue(visible ? "alert" : "background", forHTTPHeaderField: "apns-push-type")
        request.setValue(visible ? "10" : "5", forHTTPHeaderField: "apns-priority") // Apple requires 5 for background pushes.
        request.setValue(collapseID, forHTTPHeaderField: "apns-collapse-id")
        request.setValue(String(expiration), forHTTPHeaderField: "apns-expiration")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = payload
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String ?? ""
            throw ApplePushError(status: status, reason: reason)
        }
    }
}

/// What Apple carries: nothing readable about a request (keyring.proto, "The push").
public enum PushPayload {
    /// Apple refuses a payload over this.
    public static let largest = 4096

    /// Per-device APNs fallback categories for visible waiting request pushes.
    static let phoneRequestCategory = "REQUEST"
    static let watchRequestCategory = "WATCH_REQUEST"

    public static func requestCategory(for kind: Agentkeyring_V2_DeviceKind) -> String? {
        switch kind {
        case .iphone: phoneRequestCategory
        case .watch: watchRequestCategory
        default: nil
        }
    }

    /// True when the push should use `apns-push-type: alert` and `apns-priority: 10`.
    /// iPhone and Apple Watch use high-priority alert transport for both waiting requests and passive
    /// outcome collapses so `apns-collapse-id` reliably replaces waiting alerts without background throttling.
    /// Macs keep silent background transport because they handle pushes in-process with no NSE.
    public static func usesAlertTransport(waiting: Bool, for kind: Agentkeyring_V2_DeviceKind) -> Bool {
        switch kind {
        case .iphone, .watch: true
        case .mac: false
        default: waiting
        }
    }

    /// `waiting`: a new request, shown and sounded; otherwise an outcome push.
    /// Visible waiting pushes carry their device's fallback category ("REQUEST" for iPhone,
    /// "WATCH_REQUEST" for Apple Watch) so a skipped notification service extension
    /// still routes to the device's approval handler rather than a dead banner.
    /// Outcome pushes for iPhone and Apple Watch use a silent passive alert (`interruption-level: passive`,
    /// `mutable-content: 1`, `content-available: 1`, no sound, no category) so APNs collapses the waiting
    /// alert in-place at priority 10 and wakes the NSE / app without being dropped as a priority-5 background push.
    public static func pushRequest(id: String, notice: Agentkeyring_V2_Notice, waiting: Bool,
                               for kind: Agentkeyring_V2_DeviceKind = .unspecified) -> Data {
        let aps: [String: Any]
        if waiting {
            var visible: [String: Any] = [
                "alert": ["title": "Agent Keyring", "body": "A request is waiting."],
                "interruption-level": "time-sensitive",
                "mutable-content": 1,
                "thread-id": id,
                "sound": "default",
            ]
            if let category = requestCategory(for: kind) {
                visible["category"] = category
            }
            aps = visible
        } else if kind == .iphone || kind == .watch {
            aps = [
                "alert": ["title": "Agent Keyring", "body": "Request answered."],
                "interruption-level": "passive",
                "mutable-content": 1,
                "content-available": 1,
                "thread-id": id,
            ]
        } else {
            aps = ["content-available": 1, "thread-id": id]
        }
        return json(["aps": aps, "id": id, "akr": ((try? notice.serializedData()) ?? Data()).base64EncodedString()])
    }

    /// The silent push that tells the iPhone the Mac's lists changed.
    public static func revisions(_ revisions: Agentkeyring_V2_Revisions) -> Data {
        json(["aps": ["content-available": 1], "rev": ["members": revisions.members, "catalogue": revisions.catalogue,
            "copies": revisions.copies]])
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
