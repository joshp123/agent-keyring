import AgentKeyringFeature
import Foundation

@MainActor
final class CLIApprovalStatusLines {
    private let diagnostics: FileHandle?
    private var askedAt: Date?
    private var phase: AgentApprovalPhase?

    init(diagnostics: FileHandle?) { self.diagnostics = diagnostics }

    func receive(_ status: AgentBridgeWaitStatus) {
        guard let diagnostics else { return }
        switch status {
        case let .progress(progress):
            if let promptStartedAt = progress.askedAt, askedAt != promptStartedAt {
                askedAt = promptStartedAt
                write("Asked Josh on his Mac at \(approvalTime(promptStartedAt)).\n", to: diagnostics)
            }
            if phase != progress.phase, progress.phase == .waitingForUnlock {
                write("Josh's Mac is locked; waiting for him to unlock it.\n", to: diagnostics)
            }
            phase = progress.phase
        case let .stillWaiting(progress):
            if let promptStartedAt = progress.askedAt {
                write("Still waiting for Josh (asked at \(approvalTime(promptStartedAt))).\n", to: diagnostics)
            } else {
                write("Still waiting for Josh (waiting since \(approvalTime(progress.waitingSince))).\n", to: diagnostics)
            }
        }
    }
}

func approvalTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}
