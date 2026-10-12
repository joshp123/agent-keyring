import Darwin
import Foundation
import SystemConfiguration

/// Process attribution supplied by the app, never by the request payload.
public struct AgentRequester: Sendable {
    public let name: String
    public let processIdentifier: pid_t
    public let context: ApprovalRequesterContext

    public init(name: String, processIdentifier: pid_t, context: ApprovalRequesterContext) {
        self.name = name
        self.processIdentifier = processIdentifier
        self.context = context
    }

    public var displayLabel: String { name }

    public static func from(peer: AgentBridgePeer) -> AgentRequester {
        guard let peerInformation = AgentDisplayLabel.processInformation(peer.processIdentifier) else {
            return AgentRequester(name: "an agent", processIdentifier: peer.processIdentifier,
                context: machineContext(processIdentifier: peer.processIdentifier))
        }
        let peerName = URL(fileURLWithPath: peerInformation.executablePath).lastPathComponent
        let startingPID = peerName == "agent-keyring" ? peerInformation.parentPID : peer.processIdentifier
        let ancestor = AgentDisplayLabel.firstAgentAncestor(startingPID: startingPID)
        let pid = ancestor?.processIdentifier ?? peer.processIdentifier
        return AgentRequester(name: ancestor.map { AgentDisplayLabel.executableLabel(path: $0.executablePath) } ?? "an agent",
            processIdentifier: pid, context: machineContext(processIdentifier: pid))
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
