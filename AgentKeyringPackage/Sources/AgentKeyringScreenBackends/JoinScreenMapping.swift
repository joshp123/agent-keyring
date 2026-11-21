// Written by AI on 2026.10.31 by model Claude Opus 5.5; rewritten on
// 2026.11.18 by the same model for protocol version 2; renamed from
// RelayBackends.swift on 2026.11.21: there is no relay.
//
// The Mac screens over MacDevice: computers and devices joining, in the menu
// bar. Plumbing only. Requests from agents on other computers no longer reach
// this Mac: those computers push to the iPhone and Apple Watch themselves.

#if os(macOS)
import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import LocalAuthentication
import Observation

/// Turns joins into the values the screens show.
@MainActor
public enum JoinScreenMapping {
    public static func enrolment(_ join: Agentkeyring_V2_PendingJoin) -> DeviceEnrolment {
        let (kind, name): (DeviceEnrolment.Kind, String) = switch join.request.joining {
        case let .machine(machine)?: (.machine, machine.label)
        case let .device(device)?: (.approver, device.label)
        case nil: (.machine, "")
        }
        return DeviceEnrolment(id: MacDevice.joinID(join), kind: kind, name: name, tailnetNode: "",
            code: "", askedAt: Date(timeIntervalSince1970: TimeInterval(join.askedUnixSeconds)))
    }
}

/// A failure with words a person can read, for the screens' alerts.
public struct ScreenFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Runs a call and turns its LeaseFailure into readable words.
@MainActor
func screenErrors(_ action: () async throws -> Void) async throws {
    do { try await action() }
    catch let failure as LeaseFailure { throw ScreenFailure(message: failure.message) }
}
#endif
