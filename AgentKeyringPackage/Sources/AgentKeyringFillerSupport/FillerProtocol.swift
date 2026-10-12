import Foundation

@objc public enum FillTypingResult: Int, Sendable {
    case filled
    case accessibilityMissing
    case screenLocked
    case targetChanged
    case failed
    case requestExpired
}

@objc(AgentKeyringFillInspection)
public final class FillInspection: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    public let bundleIdentifier: String?
    public let processIdentifier: Int32
    public let screenLocked: Bool
    public let accessibilityTrusted: Bool
    public let pageAddress: String?
    public let focusedRole: String?
    public let focusedSubrole: String?
    public let windowIdentifier: String?
    public let focusedElementIdentifier: String?

    public init(bundleIdentifier: String?, processIdentifier: Int32, screenLocked: Bool,
        accessibilityTrusted: Bool, pageAddress: String?, focusedRole: String?, focusedSubrole: String?,
        windowIdentifier: String?, focusedElementIdentifier: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.screenLocked = screenLocked
        self.accessibilityTrusted = accessibilityTrusted
        self.pageAddress = pageAddress
        self.focusedRole = focusedRole
        self.focusedSubrole = focusedSubrole
        self.windowIdentifier = windowIdentifier
        self.focusedElementIdentifier = focusedElementIdentifier
    }

    public required init?(coder: NSCoder) {
        bundleIdentifier = coder.decodeObject(of: NSString.self, forKey: "bundleIdentifier") as String?
        processIdentifier = coder.decodeInt32(forKey: "processIdentifier")
        screenLocked = coder.decodeBool(forKey: "screenLocked")
        accessibilityTrusted = coder.decodeBool(forKey: "accessibilityTrusted")
        pageAddress = coder.decodeObject(of: NSString.self, forKey: "pageAddress") as String?
        focusedRole = coder.decodeObject(of: NSString.self, forKey: "focusedRole") as String?
        focusedSubrole = coder.decodeObject(of: NSString.self, forKey: "focusedSubrole") as String?
        windowIdentifier = coder.decodeObject(of: NSString.self, forKey: "windowIdentifier") as String?
        focusedElementIdentifier = coder.decodeObject(of: NSString.self, forKey: "focusedElementIdentifier") as String?
    }

    public func encode(with coder: NSCoder) {
        coder.encode(bundleIdentifier, forKey: "bundleIdentifier")
        coder.encode(processIdentifier, forKey: "processIdentifier")
        coder.encode(screenLocked, forKey: "screenLocked")
        coder.encode(accessibilityTrusted, forKey: "accessibilityTrusted")
        coder.encode(pageAddress, forKey: "pageAddress")
        coder.encode(focusedRole, forKey: "focusedRole")
        coder.encode(focusedSubrole, forKey: "focusedSubrole")
        coder.encode(windowIdentifier, forKey: "windowIdentifier")
        coder.encode(focusedElementIdentifier, forKey: "focusedElementIdentifier")
    }

    public func typingRefusal(comparedTo expected: FillInspection) -> FillTypingResult? {
        if screenLocked { return .screenLocked }
        if !accessibilityTrusted { return .accessibilityMissing }
        guard bundleIdentifier != nil, pageAddress != nil,
            windowIdentifier != nil, focusedElementIdentifier != nil,
            processIdentifier == expected.processIdentifier,
            bundleIdentifier == expected.bundleIdentifier,
            pageAddress == expected.pageAddress,
            windowIdentifier == expected.windowIdentifier,
            focusedElementIdentifier == expected.focusedElementIdentifier,
            focusedRole == expected.focusedRole,
            focusedSubrole == expected.focusedSubrole,
            !expected.screenLocked, expected.accessibilityTrusted
        else { return .targetChanged }
        return nil
    }
}

@objc public protocol AgentKeyringFillerProtocol {
    func inspect(withReply reply: @escaping (FillInspection) -> Void)
    func type(value: NSMutableData, expected: FillInspection, deadline: Date, withReply reply: @escaping (FillTypingResult) -> Void)
}

public func fillerInterface() -> NSXPCInterface {
    NSXPCInterface(with: AgentKeyringFillerProtocol.self)
}
