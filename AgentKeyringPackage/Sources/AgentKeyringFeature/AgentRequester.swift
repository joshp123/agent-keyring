import Darwin
import Foundation
import SystemConfiguration

/// Attribution only. The harness name does not establish authority to release credentials.
public struct AgentRequester: Sendable {
    public let name: String
    public let processIdentifier: pid_t
    public let processStartTime: HarnessProcessStartTime?
    public let workingDirectory: String?
    public let machineName: String
    public let networkAddress: String?

    public init(name: String, processIdentifier: pid_t, processStartTime: HarnessProcessStartTime?,
        workingDirectory: String?, machineName: String, networkAddress: String?) {
        self.name = name
        self.processIdentifier = processIdentifier
        self.processStartTime = processStartTime
        self.workingDirectory = workingDirectory
        self.machineName = machineName
        self.networkAddress = networkAddress
    }

    public var session: HarnessSession? {
        processStartTime.map { HarnessSession(processIdentifier: processIdentifier, processStartTime: $0) }
    }

    public var approvalContext: ApprovalRequesterContext {
        ApprovalRequesterContext(session: session, workingDirectory: workingDirectory)
    }

    public var displayLabel: String { name }

    public static func from(peer: AgentBridgePeer) -> AgentRequester {
        attribution(peerProcessIdentifier: peer.processIdentifier)
    }

    static func attribution(peerProcessIdentifier: pid_t,
        processInfo: (pid_t) -> (executablePath: String, parentPID: pid_t)? = AgentDisplayLabel.processInformation,
        startTime: (pid_t) -> HarnessProcessStartTime? = processStartTime,
        folder: (pid_t) -> String? = workingDirectory
    ) -> AgentRequester {
        let peerInformation = processInfo(peerProcessIdentifier)
        let peerName = peerInformation.map { URL(fileURLWithPath: $0.executablePath).lastPathComponent }
        let startingPID = peerName == "agent-keyring" ? peerInformation!.parentPID : peerProcessIdentifier
        let ancestor = AgentDisplayLabel.firstAgentAncestor(startingPID: startingPID, processInfo: processInfo)
        let pid = ancestor?.processIdentifier ?? peerProcessIdentifier
        let startedAt = startTime(pid)
        let currentFolder = folder(pid)
        // Attribute a stable process incarnation, never a PID that changed during the read.
        let unchanged = startedAt != nil && startedAt == startTime(pid)
        return AgentRequester(name: ancestor.map { AgentDisplayLabel.executableLabel(path: $0.executablePath) } ?? "an agent",
            processIdentifier: pid, processStartTime: unchanged ? startedAt : nil, workingDirectory: currentFolder,
            machineName: SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ProcessInfo.processInfo.hostName,
            networkAddress: primaryIPv4Address())
    }

    static func processStartTime(_ pid: pid_t) -> HarnessProcessStartTime? {
        var information = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, Int32(size)) == size else { return nil }
        return HarnessProcessStartTime(seconds: information.pbi_start_tvsec, microseconds: information.pbi_start_tvusec)
    }

    private static func workingDirectory(_ pid: pid_t) -> String? {
        var information = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &information, Int32(size)) == size else { return nil }
        let path = withUnsafeBytes(of: &information.pvi_cdir.vip_path) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
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
