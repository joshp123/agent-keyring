import Darwin
import Foundation
import Security
import SystemConfiguration
import AgentKeyringFillerSupport

public struct VerifiedRequesterIdentity: Hashable, Sendable {
    public let signingIdentifier: String
    public let teamIdentifier: String?
    public let signer: String

    public init(signingIdentifier: String, teamIdentifier: String?, signer: String) {
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.signer = signer
    }
}

/// App-computed facts. No part of this record is accepted from the CLI's request.
public struct AgentRequester: Sendable {
    public let name: String
    public let verifiedIdentity: VerifiedRequesterIdentity?
    public let processIdentifier: pid_t
    public let context: ApprovalRequesterContext
    public init(name: String, verifiedIdentity: VerifiedRequesterIdentity?, processIdentifier: pid_t,
        context: ApprovalRequesterContext) {
        self.name = name
        self.verifiedIdentity = verifiedIdentity
        self.processIdentifier = processIdentifier
        self.context = context
    }

    public var displayLabel: String {
        if let verifiedIdentity { return "\(name), verified (\(verifiedIdentity.signer))" }
        return "\(name), unverified"
    }

    public static func from(peer: AgentBridgePeer) -> AgentRequester {
        // Resolve the live peer by its audit token, which includes the PID incarnation.
        var peerCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: peer.auditToken] as CFDictionary,
            [], &peerCode) == errSecSuccess, let peerCode,
            let peerInformation = AgentDisplayLabel.processInformation(peer.processIdentifier),
            let ancestor = AgentDisplayLabel.firstAgentAncestor(
                startingPID: isBundledCLI(peerCode) ? peerInformation.parentPID : peer.processIdentifier,
                skipInterpreters: false)
        else {
            return unverified(processIdentifier: peer.processIdentifier)
        }
        let name = AgentDisplayLabel.executableLabel(path: ancestor.executablePath)
        // Interpreters establish the runtime's identity, never a script's publisher.
        let runtime = URL(fileURLWithPath: ancestor.executablePath).lastPathComponent.lowercased()
        let isInterpreter = ["node", "nodejs", "ruby", "perl", "bun", "deno"].contains(runtime) || runtime.hasPrefix("python")
        let before = processStartTime(ancestor.processIdentifier)
        let identity = isInterpreter ? nil : RequesterCodeSignature.verify(processIdentifier: ancestor.processIdentifier, name: name)
        let unchanged = before != nil && before == processStartTime(ancestor.processIdentifier)
            && AgentDisplayLabel.processInformation(ancestor.processIdentifier)?.executablePath == ancestor.executablePath
        return AgentRequester(name: name, verifiedIdentity: unchanged ? identity : nil,
            processIdentifier: ancestor.processIdentifier, context: machineContext(processIdentifier: ancestor.processIdentifier))
    }

    static func unverified(processIdentifier: pid_t) -> AgentRequester {
        AgentRequester(name: "an agent", verifiedIdentity: nil, processIdentifier: processIdentifier,
            context: machineContext(processIdentifier: processIdentifier))
    }

    private static func isBundledCLI(_ peerCode: SecCode) -> Bool {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agent-keyring")
        var bundledCode: SecStaticCode?
        var peerStaticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &bundledCode) == errSecSuccess,
            let bundledCode, SecCodeCopyStaticCode(peerCode, [], &peerStaticCode) == errSecSuccess,
            let peerStaticCode, SecCodeCheckValidity(peerCode, [], nil) == errSecSuccess else { return false }
        func codeHash(_ code: SecStaticCode) -> Data? {
            var dictionary: CFDictionary?
            guard SecCodeCopySigningInformation(code, [], &dictionary) == errSecSuccess,
                let information = dictionary as? [String: Any] else { return nil }
            return information[kSecCodeInfoUnique as String] as? Data
        }
        guard let expected = codeHash(bundledCode) else { return false }
        return expected == codeHash(peerStaticCode)
    }

    private static func processStartTime(_ pid: pid_t) -> [UInt64]? {
        var information = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, Int32(size)) == size else { return nil }
        return [information.pbi_start_tvsec, information.pbi_start_tvusec]
    }

    private static func machineContext(processIdentifier: pid_t) -> ApprovalRequesterContext {
        var information = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        var folder: String?
        if proc_pidinfo(processIdentifier, PROC_PIDVNODEPATHINFO, 0, &information, Int32(size)) == size {
            folder = withUnsafeBytes(of: &information.pvi_cdir.vip_path) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            if folder?.isEmpty == true { folder = nil }
        }
        return ApprovalRequesterContext(machineName: SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ProcessInfo.processInfo.hostName,
            workingDirectory: folder, networkAddress: primaryIPv4Address())
    }

    private static func primaryIPv4Address() -> String? {
        let store = SCDynamicStoreCreate(nil, "AgentKeyring" as CFString, nil, nil)
        if let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
            let interface = global["PrimaryInterface"] as? String,
            let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(interface)/IPv4" as CFString) as? [String: Any],
            let addresses = ipv4["Addresses"] as? [String], let address = addresses.first { return address }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var pointer = interfaces
        while let interface = pointer {
            defer { pointer = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                (interface.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                (interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}

public enum RequesterCodeSignature {
    // Observed with codesign -dv/-dr on this Mac, 2026-10-12. Nix claude and
    // agent-browser are ad hoc; pi is unsigned. They have no trusted publisher.
    private static let trustedAgents: [String: (signer: String, requirements: [BrowserSigningRequirement])] = [
        "Claude Code": ("Anthropic", [
            BrowserSigningRequirement(bundleIdentifier: "claude", teamIdentifier: "Q6L2SF6YDW"),
            BrowserSigningRequirement(bundleIdentifier: "com.anthropic.claudefordesktop", teamIdentifier: "Q6L2SF6YDW"),
            BrowserSigningRequirement(bundleIdentifier: "com.anthropic.claudefordesktop.helper", teamIdentifier: "Q6L2SF6YDW"),
        ]),
        "Codex": ("OpenAI", [
            BrowserSigningRequirement(bundleIdentifier: "codex", teamIdentifier: "2DC432GLL2"),
            BrowserSigningRequirement(bundleIdentifier: "codex-code-mode-host", teamIdentifier: "2DC432GLL2"),
            BrowserSigningRequirement(bundleIdentifier: "com.openai.codex", teamIdentifier: "2DC432GLL2"),
        ]),
    ]

    public static func verify(processIdentifier: pid_t, name: String) -> VerifiedRequesterIdentity? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: processIdentifier] as CFDictionary,
            [], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return verify(staticCode: staticCode, name: name) { requirement in
            SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }
    }

    public static func verify(executableURL: URL, name: String? = nil) -> VerifiedRequesterIdentity? {
        let resolved = executableURL.resolvingSymlinksInPath()
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(resolved as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return verify(staticCode: code, name: name ?? AgentDisplayLabel.executableLabel(path: resolved.path)) { requirement in
            SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
        }
    }

    private static func verify(staticCode: SecStaticCode, name: String,
        check: (SecRequirement) -> Bool) -> VerifiedRequesterIdentity? {
        var dictionary: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
            let information = dictionary as? [String: Any],
            let identifier = information[kSecCodeInfoIdentifier as String] as? String,
            let flags = information[kSecCodeInfoFlags as String] as? UInt32,
            flags & SecCodeSignatureFlags.adhoc.rawValue == 0 else { return nil }
        var designatedRequirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &designatedRequirement) == errSecSuccess,
            let designatedRequirement, check(designatedRequirement) else { return nil }
        let team = information[kSecCodeInfoTeamIdentifier as String] as? String
        let signer: String
        let requirementText: String
        if let trusted = trustedAgents[name] {
            guard let requirement = trusted.requirements.first(where: { $0.bundleIdentifier == identifier && $0.teamIdentifier == team }) else { return nil }
            signer = trusted.signer
            requirementText = requirement.requirementText
        } else if name == "pi" || name == "agent-browser" {
            // No publisher identity was found for either installed binary. Do not
            // learn trust from the requesting binary or its self-selected team ID.
            return nil
        } else if team == nil {
            signer = "Apple"
            requirementText = BrowserSigningRequirement(bundleIdentifier: identifier, teamIdentifier: nil).requirementText
        } else {
            // Unknown publishers have no approved agent requirement.
            return nil
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
            let requirement, check(requirement) else { return nil }
        return VerifiedRequesterIdentity(signingIdentifier: identifier, teamIdentifier: team, signer: signer)
    }
}
