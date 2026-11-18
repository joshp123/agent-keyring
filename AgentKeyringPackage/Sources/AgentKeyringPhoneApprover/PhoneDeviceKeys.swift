// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The iPhone's four keys (proto/agentkeyring/v2/keyring.proto, "Keys"). The
// signing and opening keys work only after Face ID, with one LAContext for
// both; the reply and notice keys work whenever the phone is unlocked.

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
    func sign(_ bytes: Data, context: LAContext) throws -> Data
    func open(_ sealed: SealedLogin, context: LAContext) throws -> LoginSecret
    func signReply(_ bytes: Data) throws -> Data
}
