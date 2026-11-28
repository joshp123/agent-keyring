// Written by AI on 2026.10.31 by model Claude Opus 5.5; edited on 2026.11.18
// and 2026.11.21 by the same model.
//
// The Mac screens over MacSyncCoordinator: computers and devices joining, in the menu
// bar. Plumbing only. Requests from agents on other computers no longer reach
// this Mac: those computers push to the iPhone and Apple Watch themselves.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import AgentKeyringEngine
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import LocalAuthentication
import Observation

/// Turns joins into the values the screens show.
@MainActor
public enum JoinScreenMapping {
    public static func enrolment(_ join: Agentkeyring_V2_PendingJoin) -> DeviceEnrolment {
        let (kind, name): (DeviceEnrolmentKind, String) = switch join.request.joining {
        case let .machine(machine)?: (.machine, machine.label)
        case let .device(device)?: (.approver, device.label)
        case nil: (.machine, "")
        }
        return DeviceEnrolment(id: MacSyncCoordinator.joinID(join), kind: kind, name: name,
            code: "", askedAt: Date(timeIntervalSince1970: TimeInterval(join.askedUnixSeconds)))
    }
}

/// A failure with words a person can read, for the screens' alerts.
public struct ScreenFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Runs a call and turns its AgentRPCError / AgentRPCError into readable words.
@MainActor
func screenErrors(_ action: () async throws -> Void) async throws {
    do { try await action() }
    catch let failure as AgentRPCError { throw ScreenFailure(message: failure.message) }
}
#endif
