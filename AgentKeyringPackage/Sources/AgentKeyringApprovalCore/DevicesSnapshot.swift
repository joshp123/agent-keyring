// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// The devices and computers in the signed list, as both the Mac's Devices tab
// and the iPhone's show them. A Mac Josh approves on and the computer its
// agents run on are two entries in the list that share one key; here they are
// one approver that `alsoAsks`, so its one Remove takes both, and the computer
// half is not listed again. The Mac and the iPhone each pass in how they tell
// the halves apart (CredentialSealing.pairedMac), so both screens follow the same rule.

import Foundation

public enum SignedListDeviceKind: Hashable, Sendable {
    case iPhone, watch, mac
}

/// A device in the signed list: it approves.
public struct SignedListDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var kind: SignedListDeviceKind
    public init(id: String, name: String, kind: SignedListDeviceKind) { self.id = id; self.name = name; self.kind = kind }
}

/// A computer in the signed list: its agents ask.
public struct SignedListComputer: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct SignedListApprover: Identifiable, Hashable, Sendable {
    public var device: SignedListDevice
    /// The device showing this list.
    public var isThisDevice: Bool
    /// A Mac whose agents also ask: removing it removes its computer too.
    public var alsoAsks: Bool
    public var id: String { device.id }
}

public struct DevicesSnapshot: Hashable, Sendable {

    /// Every device, in the list's order.
    public let approvers: [SignedListApprover]
    /// Computers that are not the other half of a Mac in `approvers`.
    public let computers: [SignedListComputer]

    /// - Parameter pairedComputers: for a Mac's device id, the ids of the computers that are its other half.
    public init(devices: [SignedListDevice], computers: [SignedListComputer], thisDeviceID: String?, pairedComputers: (String) -> Set<String>) {
        var paired = Set<String>()
        approvers = devices.map { device in
            let halves = device.kind == .mac ? pairedComputers(device.id) : []
            paired.formUnion(halves)
            return SignedListApprover(device: device, isThisDevice: device.id == thisDeviceID, alsoAsks: !halves.isEmpty)
        }
        self.computers = computers.filter { !paired.contains($0.id) }
    }
}

/// How far a device is from answering requests: shown on its row on the Mac and the iPhone.
public enum DeviceReadiness: Hashable, Sendable {
    case ready
    case waitingForNotifications
    case syncingCopies(done: Int, total: Int)
    case unavailable
}

/// A practice request sent to a device, from its row.
public enum DevicePracticeStatus: Hashable, Sendable {
    case waitingHere
    case sending
    case withApple
    case approved
    case denied
    case noAnswer
    case failed(String)

    public var isUnderWay: Bool { [.waitingHere, .sending, .withApple].contains(self) }
}

extension DevicesSnapshot {
    /// The iPhone's rows: each device, then each computer that is not half of a Mac.
    public func phoneDevices(readiness: (SignedListApprover) -> DeviceReadiness, practice: (SignedListApprover) -> DevicePracticeStatus?) -> [PhoneDevice] {
        approvers.map { approver in
            let ready = readiness(approver)
            let practice = practice(approver)
            return PhoneDevice(
                id: approver.id, name: approver.device.name, kind: approver.device.kind.phoneKind,
                detail: approver.device.kind.howItApproves, role: .approves, isThisIPhone: approver.isThisDevice,
                canPractice: ready == .ready && practice?.isUnderWay != true, canRemove: !approver.isThisDevice,
                alsoAsks: approver.alsoAsks, readiness: ready, practice: practice)
        } + computers.map { PhoneDevice(id: $0.id, name: $0.name, kind: .computer, role: .asks) }
    }
}

extension SignedListDeviceKind {
    var phoneKind: PhoneDeviceKind {
        switch self {
        case .iPhone: .iPhone
        case .watch: .watch
        case .mac: .mac
        }
    }

    /// Under its name on the iPhone: how it approves.
    public var howItApproves: String {
        switch self {
        case .iPhone: PhoneCopy.answersWithFaceID
        case .watch: PhoneCopy.answersWithTap
        case .mac: PhoneCopy.answersWithTouchID
        }
    }
}
