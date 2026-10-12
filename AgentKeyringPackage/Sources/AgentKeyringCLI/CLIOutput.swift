import AgentKeyringFeature
import Foundation

enum CLIOutput {
    static func render(_ response: AgentBridgeResponse, for command: CLICommand) throws -> String {
        switch command {
        case let .fill(field, _, _):
            guard response.filledField == field else { throw CLIError.invalidResponse }
            return "Filled.\n"
        case .acquire: return response.id.uuidString + "\n"
        case .sync:
            return "Josh has been asked to update Agent Keyring’s copy of his passwords.\n"
        case .status:
            guard let mirror = response.mirror else {
                guard let message = response.message else { throw CLIError.invalidResponse }
                return message + "\n"
            }
            let noun = mirror.credentialCount == 1 ? "login" : "logins"
            return
                "\(mirror.credentialCount) \(noun) available\n" + freshness(mirror)
                + (response.message.map { $0 + "\n" } ?? "")
        case let .find(targetURL, _):
            guard let candidates = response.candidates else { throw CLIError.invalidResponse }
            guard let mirror = response.mirror else { throw CLIError.invalidResponse }
            return renderCandidates(candidates, targetURL: targetURL) + freshness(mirror)

        }
    }

    private static func renderCandidates(
        _ candidates: [CredentialCandidate],
        targetURL: String
    ) -> String {
        let loginCount = candidates.filter { $0.id != MirrorItem.exampleCredentialID }.count
        let noun = loginCount == 1 ? "login" : "logins"
        let heading = loginCount == 0 && candidates.contains { $0.id == MirrorItem.exampleCredentialID }
            ? "Example login for \(displayHost(targetURL))"
            : "\(loginCount) \(noun) found for \(displayHost(targetURL))"
        var lines = [heading]
        let accountCounts = Dictionary(
            grouping: candidates,
            by: { $0.username?.lowercased() ?? "" }
        ).mapValues(\.count)
        for candidate in candidates {
            lines += [
                "",
                candidate.title,
                "  Account: \(candidate.username ?? "No username")",
                "  Can copy: \(candidate.availableFields.map(\.displayName).joined(separator: ", "))",
            ]
            if candidate.isPossiblyStale {
                lines.append("  Possibly stale: this login was rejected; update from Apple Passwords.")
            }
            if accountCounts[candidate.username?.lowercased() ?? "", default: 0] > 1 {
                lines.append("  Credential ID: \(candidate.id.uuidString)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func freshness(_ mirror: AgentMirrorSummary) -> String {
        let warning = mirror.ageSeconds > 7 * 86_400
            ? "Warning: the mirror is older than 7 days. Update it from Apple Passwords.\n" : ""
        return mirrorAge(mirror) + warning
    }

    static func mirrorAge(_ mirror: AgentMirrorSummary) -> String {
        "Updated \(age(mirror.ageSeconds))\n"
    }

    private static func age(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: "just now"
        case ..<3_600: unit(seconds / 60, "minute") + " ago"
        case ..<86_400: unit(seconds / 3_600, "hour") + " ago"
        default: unit(seconds / 86_400, "day") + " ago"
        }
    }

    private static func unit(_ value: Int, _ name: String) -> String {
        "\(value) \(value == 1 ? name : name + "s")"
    }
}
