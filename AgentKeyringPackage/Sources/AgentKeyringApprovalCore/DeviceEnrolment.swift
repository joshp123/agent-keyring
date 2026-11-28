// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// A machine, or in release 4 an iPhone, asking to join (RFC 0005). Plain
// values; the backend builds them from the relay approver's records.

import Foundation

public enum DeviceEnrolmentKind: Hashable, Sendable {
    /// An agent machine that will ask for logins.
    case machine
    /// A device that will approve requests: the iPhone.
    case approver
}

public struct DeviceEnrolment: Identifiable, Hashable, Sendable {

    public let id: String
    public var kind: DeviceEnrolmentKind
    /// Claim: the name given when enrolment was started there.
    public var name: String
    /// Computed on this device from the enrolment transcript, never taken from
    /// the relay. Eight groups of four hex characters.
    public var code: String
    public var askedAt: Date
    /// Fact from this Mac's key set: the name of the paired iPhone this one
    /// replaces, matched by its TLS key. Nil for a new device.
    public var replacesPhone: String?

    public init(id: String, kind: DeviceEnrolmentKind, name: String, code: String, askedAt: Date,
        replacesPhone: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.code = code
        self.askedAt = askedAt
        self.replacesPhone = replacesPhone
    }
}
