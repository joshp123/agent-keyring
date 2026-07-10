import Darwin
import Foundation
import AgentKeyringFeature

@main
struct AgentKeyringCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["install"] {
                writeJSON(try installIntegration())
                return
            }
            let request = try parse(arguments)
            let response = try await send(request)
            writeJSON(response)
            if !response.ok { exit(1) }
        } catch let error as CLIError {
            writeJSON(CLIErrorResponse(ok: false, error: error.code, message: error.message))
            exit(2)
        } catch {
            writeJSON(
                CLIErrorResponse(
                    ok: false,
                    error: "bridge_unavailable",
                    message: "Agent Keyring could not be reached."
                )
            )
            exit(1)
        }
    }

    private static func installIntegration() throws -> CLIInstallResponse {
        let fileManager = FileManager.default
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let helpersDirectory = executable.deletingLastPathComponent()
        let contentsDirectory = helpersDirectory.deletingLastPathComponent()
        let application = contentsDirectory.deletingLastPathComponent()
        guard
            executable.lastPathComponent == "agent-keyring",
            helpersDirectory.lastPathComponent == "Helpers",
            contentsDirectory.lastPathComponent == "Contents",
            application.pathExtension == "app"
        else {
            throw CLIError(
                "not_bundled",
                "Run install using the agent-keyring helper inside AgentKeyring.app."
            )
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let commandDestination = home.appendingPathComponent(".local/bin/agent-keyring")
        let codexHome =
            ProcessInfo.processInfo.environment["CODEX_HOME"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? home.appendingPathComponent(".codex", isDirectory: true)
        let skillSource =
            contentsDirectory
            .appendingPathComponent("Resources/AgentTools/CodexSkill/agent-keyring")
        let skillDestination = codexHome.appendingPathComponent("skills/agent-keyring")
        guard fileManager.fileExists(atPath: skillSource.path) else {
            throw CLIError("skill_missing", "The bundled Codex skill is missing.")
        }

        try replaceSymlink(at: commandDestination, with: executable)
        try replaceSymlink(at: skillDestination, with: skillSource)
        return CLIInstallResponse(
            ok: true,
            commandPath: commandDestination.path,
            skillPath: skillDestination.path,
            restartCodex: false
        )
    }

    private static func replaceSymlink(at destination: URL, with source: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let existingTarget = try? fileManager.destinationOfSymbolicLink(
            atPath: destination.path
        ) {
            if URL(
                fileURLWithPath: existingTarget, relativeTo: destination.deletingLastPathComponent()
            )
            .standardizedFileURL == source.standardizedFileURL {
                return
            }
            try fileManager.removeItem(at: destination)
        } else if fileManager.fileExists(atPath: destination.path) {
            throw CLIError(
                "install_conflict",
                "Refusing to replace the existing file at \(destination.path)."
            )
        }

        try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
    }

    private static func parse(_ arguments: [String]) throws -> AgentBridgeRequest {
        guard let command = arguments.first else { throw CLIError.usage }
        if command == "help" || command == "--help" || command == "-h" {
            FileHandle.standardOutput.write(Data(help.utf8))
            exit(0)
        }

        let options = try parseOptions(Array(arguments.dropFirst()))
        switch command {
        case "status":
            guard options.isEmpty else { throw CLIError.usage }
            return AgentBridgeRequest(action: .status)
        case "resolve":
            let targetURL = try required("url", from: options)
            try rejectUnknown(options, allowed: ["url", "username"])
            return AgentBridgeRequest(
                action: .resolve,
                targetURL: targetURL,
                usernameHint: options["username"]
            )
        case "copy":
            let targetURL = try required("url", from: options)
            let fieldText = try required("field", from: options)
            guard let field = AgentCredentialField(rawValue: fieldText) else {
                throw CLIError("invalid_field", "Field must be username, password or totp.")
            }
            let candidateID: UUID?
            if let candidate = options["candidate"] {
                guard let id = UUID(uuidString: candidate) else {
                    throw CLIError(
                        "invalid_candidate", "Candidate must be a UUID returned by resolve.")
                }
                candidateID = id
            } else {
                candidateID = nil
            }
            let expiration: Int
            if let value = options["expires"] {
                guard let seconds = Int(value), (5...120).contains(seconds) else {
                    throw CLIError(
                        "invalid_expiration", "Expiration must be between 5 and 120 seconds.")
                }
                expiration = seconds
            } else {
                expiration = 30
            }
            try rejectUnknown(
                options,
                allowed: ["url", "username", "candidate", "field", "expires"]
            )
            return AgentBridgeRequest(
                action: .copy,
                targetURL: targetURL,
                usernameHint: options["username"],
                candidateID: candidateID,
                field: field,
                expirationSeconds: expiration
            )
        default:
            throw CLIError.usage
        }
    }

    private static func parseOptions(_ arguments: [String]) throws -> [String: String] {
        var result = [String: String]()
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard option.hasPrefix("--"), option.count > 2, index + 1 < arguments.count else {
                throw CLIError.usage
            }
            let key = String(option.dropFirst(2))
            guard result[key] == nil else {
                throw CLIError("duplicate_option", "Option --\(key) was provided more than once.")
            }
            result[key] = arguments[index + 1]
            index += 2
        }
        return result
    }

    private static func required(_ key: String, from options: [String: String]) throws -> String {
        guard let value = options[key], !value.isEmpty else {
            throw CLIError("missing_option", "Missing required option --\(key).")
        }
        return value
    }

    private static func rejectUnknown(
        _ options: [String: String],
        allowed: Set<String>
    ) throws {
        guard let unknown = options.keys.first(where: { !allowed.contains($0) }) else { return }
        throw CLIError("unknown_option", "Unknown option --\(unknown).")
    }

    private static func send(_ request: AgentBridgeRequest) async throws -> AgentBridgeResponse {
        let bridge = AgentBridgeDirectory()
        bridge.removeResponse(id: request.id)
        try bridge.write(request)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-g",
            "-b",
            AgentBridgeDirectory.applicationBundleIdentifier,
            "agentkeyring://agent/\(request.id.uuidString)",
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            bridge.removeRequest(id: request.id)
            throw CLIError(
                "app_unavailable",
                "Agent Keyring is not installed or could not be launched."
            )
        }

        for _ in 0..<1_200 {
            if bridge.responseExists(id: request.id) {
                let response = try bridge.readResponse(id: request.id)
                bridge.removeResponse(id: request.id)
                return response
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        bridge.removeRequest(id: request.id)
        throw CLIError("timed_out", "Agent Keyring did not answer within 120 seconds.")
    }

    private static func writeJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static let help = """
        agent-keyring — use the local encrypted Agent Keyring without printing secrets

        Usage:
          agent-keyring install
          agent-keyring status
          agent-keyring resolve --url URL [--username USERNAME]
          agent-keyring copy --url URL --field username|password|totp
                        [--username USERNAME] [--candidate UUID] [--expires 30]

        Every command returns JSON. Saved access rules decide whether password and
        verification-code copies require approval, run automatically or are blocked.
        copy clears the clipboard after 30 seconds by default; the value never appears
        in command output.
        """
}

private struct CLIError: Error {
    let code: String
    let message: String

    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    static let usage = CLIError("usage", "Run agent-keyring help for usage.")
}

private struct CLIErrorResponse: Encodable {
    let ok: Bool
    let error: String
    let message: String
}

private struct CLIInstallResponse: Encodable {
    let ok: Bool
    let commandPath: String
    let skillPath: String
    let restartCodex: Bool
}
