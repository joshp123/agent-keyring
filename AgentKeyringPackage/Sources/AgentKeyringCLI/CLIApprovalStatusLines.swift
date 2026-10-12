import AgentKeyringFeature
import Foundation

@MainActor
final class CLIApprovalStatusLines {
    private let diagnostics: FileHandle?
    private var askedAt: Date?
    private var provider: ApprovalPromptProvider?
    private var phase: AgentApprovalPhase?

    init(diagnostics: FileHandle?) { self.diagnostics = diagnostics }

    func receive(_ status: AgentBridgeWaitStatus) {
        guard let diagnostics else { return }
        switch status {
        case let .progress(progress):
            if let promptStartedAt = progress.askedAt,
                askedAt != promptStartedAt || provider != progress.provider {
                askedAt = promptStartedAt
                provider = progress.provider
                let line: String
                if progress.provider == .iPhone {
                    line = progress.macWasLocked == true
                        ? "\(MacOwner.firstName)'s Mac is locked; asked on the iPhone at \(approvalTime(promptStartedAt))."
                        : "Asked \(MacOwner.firstName) on the iPhone at \(approvalTime(promptStartedAt))."
                } else if let phoneAt = progress.phoneScheduledAt {
                    line = "Asked \(MacOwner.firstName) on the Mac at \(approvalTime(promptStartedAt)); will ask on the iPhone at \(approvalTime(phoneAt))."
                } else {
                    line = "Asked \(MacOwner.firstName) on the Mac at \(approvalTime(promptStartedAt))."
                }
                write(line + "\n", to: diagnostics)
            }
            if phase != progress.phase, progress.phase == .waitingForUnlock {
                write("\(MacOwner.firstName)'s Mac is locked; waiting for an unlock.\n", to: diagnostics)
            }
            phase = progress.phase
        case let .stillWaiting(progress):
            if let promptStartedAt = progress.askedAt {
                write("Still waiting for \(MacOwner.firstName) (asked at \(approvalTime(promptStartedAt))).\n", to: diagnostics)
            } else {
                write("Still waiting for \(MacOwner.firstName) (waiting since \(approvalTime(progress.waitingSince))).\n", to: diagnostics)
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
