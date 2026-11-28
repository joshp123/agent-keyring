// Written by AI on 2026.11.20 by model Claude Opus 5.5.
//
// Whether a request is this Apple Watch's own practice request or one the
// computer it names signed. CredentialSealing.verifySignedLeaseRequest returns no computer for the
// first and throws for an unsigned request or a foreign answer box; `try?`
// would flatten both to nil.

import AgentKeyringProtocol

/// True for this device's own practice request, false for a request its computer signed; throws for anything else.
public func isOwnPractice(_ envelope: Agentkeyring_V2_SignedRequestEnvelope, members: Members, ownKeyID: String) throws -> Bool {
    do { return try CredentialSealing.verifySignedLeaseRequest(envelope, members: members, ownKeyID: ownKeyID) == nil }
    catch { throw UnsignedWatchRequestError() }
}

public struct UnsignedWatchRequestError: Error, CustomStringConvertible {
    public var description: String { "the request was not signed by the machine it names, or names an answer box this Watch may not use" }
}
