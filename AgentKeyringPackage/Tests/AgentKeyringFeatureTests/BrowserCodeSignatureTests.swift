import AgentKeyringFillerSupport
import Foundation
import Security
import Testing

@Suite("Browser signing requirements")
struct BrowserCodeSignatureTests {
    @Test("Vendor identity rejects bundle-ID impersonation", arguments: [
        "genuine", "wrong-team", "unsigned", "ad-hoc", "self-signed", "wrong-identifier", "invalid",
    ])
    func vendorIdentity(path: String) throws {
        let requirement = try #require(TrustedBrowsers.requirement(for: "com.google.Chrome"))
        let authority: BrowserSigningInformation.Authority = switch path {
        case "unsigned": .unsigned
        case "ad-hoc": .adHoc
        case "self-signed": .other
        default: .developerIDOrAppStore
        }
        let signingInformation = BrowserSigningInformation(
            identifier: path == "wrong-identifier" ? "com.google.Chrome.canary" : "com.google.Chrome",
            teamIdentifier: path == "wrong-team" ? "ATTACKER01" : "EQHXZ8M8AV",
            authority: authority, isValid: path != "invalid" && path != "unsigned")
        #expect(requirement.matches(signingInformation) == (path == "genuine"))
    }

    @Test("Safari requires Apple signing, even with a valid vendor signature")
    func safariIdentity() throws {
        let requirement = try #require(TrustedBrowsers.requirement(for: "com.apple.Safari"))
        #expect(requirement.matches(BrowserSigningInformation(identifier: "com.apple.Safari",
            teamIdentifier: nil, authority: .apple, isValid: true)))
        for authority in [BrowserSigningInformation.Authority.developerIDOrAppStore, .adHoc, .unsigned, .other] {
            #expect(!requirement.matches(BrowserSigningInformation(identifier: "com.apple.Safari",
                teamIdentifier: "ATTACKER01", authority: authority, isValid: true)))
        }
    }

    @Test("Every allowlist entry compiles into a Security requirement and refuses this process",
        arguments: TrustedBrowsers.requirements.map(\.bundleIdentifier))
    func realRequirements(bundleIdentifier: String) throws {
        let browser = try #require(TrustedBrowsers.requirement(for: bundleIdentifier))
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(browser.requirementText as CFString, [], &requirement) == errSecSuccess)
        let compiled = try #require(requirement)
        var code: SecCode?
        #expect(SecCodeCopySelf([], &code) == errSecSuccess)
        #expect(SecCodeCheckValidity(try #require(code), [], compiled) != errSecSuccess)
        #expect(!TrustedBrowsers.verify(processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: bundleIdentifier))
    }

    @Test("Unknown browsers and nonexistent processes are refused")
    func unsupportedIdentity() {
        #expect(TrustedBrowsers.requirement(for: "com.attacker.Browser") == nil)
        #expect(TrustedBrowsers.requirement(for: nil) == nil)
        #expect(!TrustedBrowsers.verify(processIdentifier: -1, bundleIdentifier: "com.google.Chrome"))
    }
}
