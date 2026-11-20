// Written by AI on 2026.11.20 by model Claude Opus 5.5.
//
// Whether a request is this Apple Watch's own practice request or one the
// computer it names signed. Sealing.checkRequest returns no computer for the
// first and throws for an unsigned request; `try?` would flatten both to nil.

import AgentKeyringProtocol
import AgentKeyringSealing

/// True for this device's own practice request, false for a request its computer signed; throws for anything else.
public func isOwnPractice(_ work: Agentkeyring_V2_Work, members: Members, ownKeyID: String) throws -> Bool {
    do { return try Sealing.checkRequest(work, members: members, ownKeyID: ownKeyID) == nil }
    catch { throw UnsignedRequest() }
}

public struct UnsignedRequest: Error, CustomStringConvertible {
    public var description: String { "the request was not signed by the machine it names" }
}
