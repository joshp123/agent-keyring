import CoreGraphics
import Foundation

@MainActor
public protocol CredentialSessionLockState {
    var isLocked: Bool { get }
}

public struct SystemCredentialSessionLockState: CredentialSessionLockState {
    public init() {}

    public var isLocked: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0 || Self.isLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    static func isLocked(session: [String: Any]?) -> Bool {
        guard let session else { return true }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
