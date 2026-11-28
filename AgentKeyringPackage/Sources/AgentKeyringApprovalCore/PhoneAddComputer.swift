// Written by AI on 2026.11.23 by model claude opus 5.5.
//
// What the iPhone shows while copying from Passwords, and while adding
// another computer with a one-time code, with no Mac: each a plain value the
// backend sets and the pages draw.

import Foundation

/// Copying from Passwords on this iPhone.
public struct PhonePasswordsCopy: Hashable, Sendable {
    /// When this iPhone last had a copy from Passwords, on any of his devices; nil before the first.
    public var copiedAt: Date?
    /// Older than a week: Passwords says so, quietly.
    public var isStale = false
    /// Agent Keyring is on in Passwords, so Passwords lists it to export to.
    public var turnedOn = false
    /// An export from Passwords is arriving and being sealed.
    public var copying = false
    /// Why the last copy failed, in his words.
    public var problem: String?
    public init() {}
}

/// Thrown by Set Up on This iPhone, with what to do instead.
public struct PhoneSetUpFailure: Error {
    public let sentence: String
    public init(_ sentence: String) { self.sentence = sentence }
}

/// Adding another computer: its one-time code, then its request, then the answer.
public enum PhoneAddComputer: Hashable, Sendable {
    /// The code and the command to run on the computer, and when it runs out. The command names the relay
    /// as a link (agentkeyring://join?code=...&relay=...) when it is not the default.
    case invite(code: String, command: String, until: Date)
    /// The computer asked to join with the code.
    case asked(name: String)
    case adding(name: String)
    case added(name: String)
    case notAdded(name: String)
    case expired
    case failed(String)
    /// Membership was already committed; the computer's response box could not be reached yet and can be retried.
    case deliveryFailed(name: String, reason: String)
}

public enum PhoneAddComputerTap: Hashable, Sendable {
    case open, approve, deny, retryDelivery, newCode, close
}

/// A Mac or another iPhone asking through iCloud to join this iPhone's list, with the invitation this
/// iPhone left in iCloud Keychain.
public enum PhoneDeviceJoin: Hashable, Sendable {
    /// Waiting for Add or Don't Add. `isMac`: a Mac, which also asks for its agents.
    case asked(name: String, isMac: Bool)
    /// Added after Face ID: its copies are being encrypted.
    case adding(name: String)
}
