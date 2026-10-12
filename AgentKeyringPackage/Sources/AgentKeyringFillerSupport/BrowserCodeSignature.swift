import Foundation
import Security

public struct BrowserSigningInformation: Sendable {
    public enum Authority: Sendable {
        case apple, developerIDOrAppStore, unsigned, adHoc, other
    }

    public let identifier: String
    public let teamIdentifier: String?
    public let authority: Authority
    public let isValid: Bool

    public init(identifier: String, teamIdentifier: String?, authority: Authority, isValid: Bool) {
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.authority = authority
        self.isValid = isValid
    }
}

public struct BrowserSigningRequirement: Sendable {
    public let bundleIdentifier: String
    public let teamIdentifier: String?

    public var requirementText: String {
        let identity = "identifier \"\(bundleIdentifier)\""
        guard let teamIdentifier else { return identity + " and anchor apple" }
        return identity + " and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
            + " and ((certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists)"
            + " or certificate leaf[field.1.2.840.113635.100.6.1.9] exists)"
    }

    public func matches(_ information: BrowserSigningInformation) -> Bool {
        guard information.isValid, information.identifier == bundleIdentifier else { return false }
        guard let teamIdentifier else { return information.authority == .apple }
        return information.teamIdentifier == teamIdentifier
            && information.authority == .developerIDOrAppStore
    }
}

public enum TrustedBrowsers {
    public static let requirements: [BrowserSigningRequirement] = [
        // codesign -dv --verbose=4 /Applications/Safari.app, 2026-10-12; Apple system signing, no team ID.
        BrowserSigningRequirement(bundleIdentifier: "com.apple.Safari", teamIdentifier: nil),
        // codesign -dv --verbose=4 "/Applications/Google Chrome.app", 2026-10-12.
        BrowserSigningRequirement(bundleIdentifier: "com.google.Chrome", teamIdentifier: "EQHXZ8M8AV"),
        // codesign -dv --verbose=4 /Applications/Claude.app, 2026-10-12.
        BrowserSigningRequirement(bundleIdentifier: "com.anthropic.claudefordesktop", teamIdentifier: "Q6L2SF6YDW"),
        // codesign -dv --verbose=4 /Applications/ChatGPT.app, 2026-10-12; installed Codex uses this app name.
        BrowserSigningRequirement(bundleIdentifier: "com.openai.codex", teamIdentifier: "2DC432GLL2"),
    ]

    public static func requirement(for bundleIdentifier: String?) -> BrowserSigningRequirement? {
        requirements.first { $0.bundleIdentifier == bundleIdentifier }
    }

    public static func verify(processIdentifier: Int32, bundleIdentifier: String?) -> Bool {
        guard let browser = requirement(for: bundleIdentifier) else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
            let code,
            SecCodeCheckValidity(code, [], nil) == errSecSuccess,
            let requirement = compile(browser.requirementText),
            SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        else { return false }
        var staticCode: SecStaticCode?
        var signingDictionary: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingDictionary) == errSecSuccess,
            let information = signingDictionary as? [String: Any],
            let identifier = information[kSecCodeInfoIdentifier as String] as? String,
            let flags = information[kSecCodeInfoFlags as String] as? UInt32
        else { return false }
        // The requirement already established the certificate chain and signing class.
        let authority: BrowserSigningInformation.Authority = (flags & SecCodeSignatureFlags.adhoc.rawValue) != 0
            ? .adHoc : (browser.teamIdentifier == nil ? .apple : .developerIDOrAppStore)
        return browser.matches(BrowserSigningInformation(identifier: identifier,
            teamIdentifier: information[kSecCodeInfoTeamIdentifier as String] as? String,
            authority: authority, isValid: true))
    }

    private static func compile(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }
}
