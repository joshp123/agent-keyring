// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The iPhone's four keys (proto/agentkeyring/v2/keyring.proto, "Keys"). The
// signing and opening keys work only after Face ID, with one LAContext for
// both; the reply and notice keys work whenever the phone is unlocked.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication

@MainActor
public protocol PhoneDeviceKeys {
    func signingPublicKey() throws -> Data
    func openingPublicKey() throws -> Data
    func replyPublicKey() throws -> Data
    func noticePublicKey() throws -> Data
    /// Shows Face ID with `reason`, or accepts a recent Face ID unlock if the
    /// context allows reuse. The same context then signs and opens.
    func authorize(_ context: LAContext, reason: String) async throws
    func signWithDeviceKey(_ bytes: Data, context: LAContext) throws -> Data
    func openSealedLogin(_ sealed: SealedLogin, context: LAContext) throws -> LoginSecret
    func signReply(_ bytes: Data) throws -> Data
    /// The reply key loaded once, to sign many copies away from the main thread.
    func replySigner() throws -> @Sendable (Data) throws -> Data
    /// The opening key loaded once with an approved context, to open many copies away from the main thread.
    func opener(context: LAContext) throws -> @Sendable (SealedLogin) throws -> LoginSecret
    /// Opens a push's notice with the notice key, which works once the phone has been unlocked after starting.
    func openNotice(_ notice: Agentkeyring_V2_Notice, deviceKeyID: String) throws -> Agentkeyring_V2_SignedRequestEnvelope
    /// Opens an HPKE-wrapped content key for an encrypted iCloud record using the notice key (no Face ID).
    func cloudKeyOpener() throws -> CloudEnvelope.KeyOpener
}

/// A value carried across threads where its type does not say it may be: a loaded key used by one task at a time.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
