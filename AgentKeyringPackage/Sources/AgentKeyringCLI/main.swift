import AgentKeyringFeature
import ArgumentParser
import Foundation

@main
struct AgentKeyringCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-keyring",
        abstract:
            "Let local agents use imported Apple Passwords logins without printing secrets.",
        discussion: """
            EXAMPLES
              agent-keyring find https://example.com
              agent-keyring copy username https://example.com
              agent-keyring copy password https://example.com
              agent-keyring copy code https://example.com
            """,
        version: installedVersion(),
        subcommands: [Find.self, Copy.self, Status.self, Install.self]
    )

    mutating func run() {
        print(
            "Agent Keyring lets local agents use imported Apple Passwords logins without printing secrets."
        )
        print("")
        print("Try:")
        print("  agent-keyring find https://example.com")
        print("  agent-keyring copy password https://example.com")
        print("")
        print("Run 'agent-keyring --help' for all commands.")
    }
}

struct Find: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show logins that match a web page without requesting a secret."
    )

    @Argument(help: "The full URL of the current web page.")
    var url: String

    @Option(help: "Only show this account.")
    var account: String?

    func validate() throws {
        try validateWebURL(url)
    }

    mutating func run() async throws {
        try await CLIClient.run(.find(targetURL: url, account: account))
    }
}

struct Copy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy one credential field without printing it."
    )

    @Argument(help: "The field to copy: username, password or code.")
    var field: CopyField

    @Argument(help: "The full URL of the current web page.")
    var url: String

    @Option(help: "Choose an account when several logins match.")
    var account: String?

    @Option(help: "Choose between duplicate account entries. Find shows the ID when needed.")
    var credential: String?

    @Option(help: "Clear the clipboard after this many seconds (5–120).")
    var expires = 30

    func validate() throws {
        try validateSecureWebURL(url)
        guard (5...120).contains(expires) else {
            throw ValidationError("--expires must be between 5 and 120 seconds.")
        }
        if let credential, UUID(uuidString: credential) == nil {
            throw ValidationError(
                "'\(credential)' is not a valid credential ID. Run 'agent-keyring find \(url)' to see matching logins."
            )
        }
    }

    mutating func run() async throws {
        try await CLIClient.run(
            .copy(
                field: field.bridgeField,
                targetURL: url,
                account: account,
                credentialID: credential.flatMap(UUID.init(uuidString:)),
                expiration: expires
            )
        )
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show how many logins are available and when they were last updated."
    )

    mutating func run() async throws {
        try await CLIClient.run(.status)
    }
}

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install the command and Codex instructions for this user."
    )

    mutating func run() throws {
        do {
            let result = try CLIClient.install()
            print("Installed Agent Keyring for Codex.")
            print("Command: \(result.commandPath)")
            print("Instructions: \(result.skillPath)")
        } catch let error as CLIError {
            try stop(error)
        } catch {
            try stop(.unavailable)
        }
    }
}

enum CopyField: String, CaseIterable, ExpressibleByArgument {
    case username
    case password
    case code

    var bridgeField: AgentCredentialField {
        switch self {
        case .username: .username
        case .password: .password
        case .code: .totp
        }
    }
}

enum CLICommand: Equatable {
    case status
    case find(targetURL: String, account: String?)
    case copy(
        field: AgentCredentialField,
        targetURL: String,
        account: String?,
        credentialID: UUID?,
        expiration: Int
    )

    var request: AgentBridgeRequest {
        switch self {
        case .status:
            AgentBridgeRequest(action: .status)
        case let .find(targetURL, account):
            AgentBridgeRequest(
                action: .resolve,
                targetURL: targetURL,
                usernameHint: account
            )
        case let .copy(field, targetURL, account, credentialID, expiration):
            AgentBridgeRequest(
                action: .copy,
                targetURL: targetURL,
                usernameHint: account,
                candidateID: credentialID,
                field: field,
                expirationSeconds: expiration
            )
        }
    }
}

enum CLIClient {
    static func run(_ command: CLICommand) async throws {
        do {
            if case let .copy(field, targetURL, _, _, _) = command {
                write(
                    "Requesting \(field.displayName) for \(displayHost(targetURL))…\n",
                    to: .standardError
                )
            }
            let response = try await send(command.request)
            guard response.ok else {
                throw CLIError(response: response, command: command)
            }
            write(try CLIOutput.render(response, for: command), to: .standardOutput)
        } catch let error as CLIError {
            try stop(error)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code)
        {
            try stop(
                CLIError(
                    "This process cannot access Agent Keyring's local data.",
                    suggestion: "Allow access and try again."
                )
            )
        } catch {
            try stop(.unavailable)
        }
    }

    static func install() throws -> CLIInstallResult {
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
                "Install Agent Keyring from the copy inside AgentKeyring.app.",
                suggestion:
                    "/Applications/AgentKeyring.app/Contents/Helpers/agent-keyring install"
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
            throw CLIError(
                "AgentKeyring.app is missing its Codex instructions.",
                suggestion: "Reinstall Agent Keyring, then try again."
            )
        }

        let integrations = [
            IntegrationLink(
                destination: commandDestination,
                source: executable,
                legacyKind: .command
            ),
            IntegrationLink(
                destination: skillDestination,
                source: skillSource,
                legacyKind: .codexSkill
            ),
        ]
        try IntegrationInstaller.install(integrations)
        return CLIInstallResult(
            commandPath: commandDestination.path,
            skillPath: skillDestination.path
        )
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
                "Agent Keyring is not installed or could not be opened.",
                suggestion: "Install AgentKeyring.app in Applications, then try again."
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
        throw CLIError(
            "Agent Keyring did not respond.",
            suggestion: "Open the app and try again."
        )
    }
}

struct IntegrationLink {
    enum LegacyKind {
        case command
        case codexSkill
    }

    let destination: URL
    let source: URL
    let legacyKind: LegacyKind
}

enum IntegrationInstaller {
    private enum State: Equatable {
        case current
        case replace
        case missing
    }

    static func install(
        _ links: [IntegrationLink],
        fileManager: FileManager = .default
    ) throws {
        // Check every destination before changing any of them. A conflict must not
        // leave the command and its instructions pointing at different installs.
        let states = try links.map { try state(of: $0, fileManager: fileManager) }

        for (link, state) in zip(links, states) where state != .current {
            try fileManager.createDirectory(
                at: link.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if state == .replace {
                try fileManager.removeItem(at: link.destination)
            }
            try fileManager.createSymbolicLink(
                at: link.destination,
                withDestinationURL: link.source
            )
        }
    }

    private static func state(
        of link: IntegrationLink,
        fileManager: FileManager
    ) throws -> State {
        if let existingTarget = try? fileManager.destinationOfSymbolicLink(
            atPath: link.destination.path
        ) {
            let target = URL(
                fileURLWithPath: existingTarget,
                relativeTo: link.destination.deletingLastPathComponent()
            ).standardizedFileURL
            return target == link.source.standardizedFileURL ? .current : .replace
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: link.destination.path, isDirectory: &isDirectory)
        else {
            return .missing
        }

        let isLegacyCopy: Bool
        switch link.legacyKind {
        case .command:
            isLegacyCopy = !isDirectory.boolValue && isAgentKeyringCommand(at: link.destination)
        case .codexSkill:
            isLegacyCopy = isDirectory.boolValue && isAgentKeyringSkill(at: link.destination)
        }
        guard isLegacyCopy else {
            throw CLIError(
                "Cannot install because \(link.destination.path) already exists.",
                suggestion: "Move it, then run the install command again."
            )
        }
        return .replace
    }

    private static func isAgentKeyringCommand(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let markers = [
            "agent-keyring — use the local encrypted Agent Keyring",
            "Let local agents use imported Apple Passwords logins without printing secrets.",
        ]
        return markers.contains { marker in
            data.range(of: Data(marker.utf8)) != nil
        }
    }

    private static func isAgentKeyringSkill(at url: URL) -> Bool {
        let skillFile = url.appendingPathComponent("SKILL.md")
        guard let contents = try? String(contentsOf: skillFile, encoding: .utf8) else {
            return false
        }
        return
            contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(12)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "name: agent-keyring" }
    }
}

enum CLIOutput {
    static func render(_ response: AgentBridgeResponse, for command: CLICommand) throws -> String {
        switch command {
        case .status:
            guard let mirror = response.mirror else { throw CLIError.invalidResponse }
            let noun = mirror.credentialCount == 1 ? "login" : "logins"
            return
                "\(mirror.credentialCount) \(noun) available\nUpdated \(age(mirror.ageSeconds))\n"
        case let .find(targetURL, _):
            guard let candidates = response.candidates else { throw CLIError.invalidResponse }
            return renderCandidates(candidates, targetURL: targetURL)
        case let .copy(field, targetURL, _, _, expiration):
            guard response.copiedField == field else { throw CLIError.invalidResponse }
            let destination =
                response.candidates?.first?.username.map {
                    "for \($0) on \(displayHost(targetURL))"
                } ?? "for \(displayHost(targetURL))"
            return
                "Copied the \(field.displayName) \(destination). Paste it within \(expiration) seconds.\n"
        }
    }

    private static func renderCandidates(
        _ candidates: [CredentialCandidate],
        targetURL: String
    ) -> String {
        let noun = candidates.count == 1 ? "login" : "logins"
        var lines = ["\(candidates.count) \(noun) found for \(displayHost(targetURL))"]
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
            if accountCounts[candidate.username?.lowercased() ?? "", default: 0] > 1 {
                lines.append("  Credential ID: \(candidate.id.uuidString)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
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

struct CLIError: Error {
    let message: String
    let suggestion: String?
    let exitCode: Int32

    init(_ message: String, suggestion: String? = nil, exitCode: Int32 = 1) {
        self.message = message
        self.suggestion = suggestion
        self.exitCode = exitCode
    }

    init(response: AgentBridgeResponse, command: CLICommand) {
        let targetURL = command.targetURL
        switch response.error {
        case .notFound:
            self.init(
                "No login matches \(displayHost(targetURL)).",
                suggestion: "Check the URL, or update Agent Keyring from Apple Passwords."
            )
        case .ambiguous:
            let accounts = response.candidates?.compactMap(\.username) ?? []
            let choices = accounts.map { "  \($0)" }.joined(separator: "\n")
            let suggestion: String
            let uniqueAccounts = Set(accounts.map { $0.lowercased() })
            if uniqueAccounts.count < accounts.count {
                suggestion =
                    "Run 'agent-keyring find \(targetURL)' to see the credential IDs, then choose one:\nagent-keyring copy \(command.fieldArgument) \(shellQuote(targetURL)) --credential UUID"
            } else if let account = accounts.first {
                suggestion =
                    "Choose an account:\n\(choices)\nTry: agent-keyring copy \(command.fieldArgument) \(shellQuote(targetURL)) --account \(shellQuote(account))"
            } else {
                suggestion = "Run 'agent-keyring find \(targetURL)' and choose a credential."
            }
            self.init(
                "More than one login matches \(displayHost(targetURL)).",
                suggestion: suggestion
            )
        case .fieldUnavailable:
            self.init("That login has no \(command.fieldName) to copy.")
        case .insecureOrigin:
            self.init(
                "Agent Keyring will not copy credentials to an insecure page.",
                suggestion: "Use the HTTPS page instead."
            )
        case .invalidURL:
            self.init(
                "'\(targetURL)' is not a complete web page URL.",
                suggestion: "Use a full URL, such as https://example.com."
            )
        case .mirrorUnavailable:
            self.init(
                "No logins are available yet.",
                suggestion: "Open Agent Keyring and import them from Apple Passwords."
            )
        case .authorizationDenied:
            self.init("The request was not approved. Nothing was copied.")
        case .authorizationUnavailable:
            self.init(
                "Agent Keyring could not show the approval window.",
                suggestion: "Open the app and try again."
            )
        case .policyDenied:
            self.init("Access to this login is blocked in Agent Keyring. Nothing was copied.")
        case .requestExpired, .timedOut:
            self.init(
                "The request expired before Agent Keyring completed it.",
                suggestion: "Try again."
            )
        case .invalidTOTP:
            self.init(
                "Agent Keyring could not create a verification code for this login.",
                suggestion: "Update Agent Keyring from Apple Passwords, then try again."
            )
        case .bridgeUnavailable, .internalError, .invalidRequest, .none:
            self.init(
                response.message ?? "Agent Keyring could not complete the request.",
                suggestion: "Open the app and try again."
            )
        }
    }

    var rendered: String {
        message + "\n" + (suggestion.map { $0 + "\n" } ?? "")
    }

    static let unavailable = CLIError(
        "Agent Keyring could not be reached.",
        suggestion: "Open the app and try again."
    )
    static let invalidResponse = CLIError(
        "Agent Keyring returned an incomplete response.",
        suggestion: "Open the app and try again."
    )
}

struct CLIInstallResult {
    let commandPath: String
    let skillPath: String
}

extension CLICommand {
    fileprivate var targetURL: String {
        switch self {
        case let .find(targetURL, _), let .copy(_, targetURL, _, _, _): targetURL
        case .status: "the requested site"
        }
    }

    fileprivate var fieldName: String {
        guard case let .copy(field, _, _, _, _) = self else { return "requested field" }
        return field.displayName
    }

    fileprivate var fieldArgument: String {
        guard case let .copy(field, _, _, _, _) = self else { return "password" }
        return field.argumentName
    }
}

extension AgentCredentialField {
    fileprivate var displayName: String {
        switch self {
        case .username: "username"
        case .password: "password"
        case .totp: "verification code"
        }
    }

    fileprivate var argumentName: String {
        switch self {
        case .username: "username"
        case .password: "password"
        case .totp: "code"
        }
    }
}

private func validateWebURL(_ value: String) throws {
    guard let components = URLComponents(string: value),
        let scheme = components.scheme?.lowercased(),
        scheme == "https" || scheme == "http",
        components.host?.isEmpty == false
    else {
        throw ValidationError(
            "'\(value)' is not a complete web page URL. Use a full URL, such as https://example.com."
        )
    }
}

func validateSecureWebURL(_ value: String) throws {
    try validateWebURL(value)
    guard let components = URLComponents(string: value),
        let host = components.host?.lowercased()
    else { return }
    let localhost = host == "localhost" || host == "127.0.0.1" || host == "::1"
    guard components.scheme?.lowercased() == "https" || localhost else {
        throw ValidationError(
            "Agent Keyring will not copy credentials to an insecure page. Use the HTTPS page instead."
        )
    }
}

private func installedVersion() -> String {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let infoURL = executable.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: infoURL),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let dictionary = plist as? [String: Any],
        let version = dictionary["CFBundleShortVersionString"] as? String
    else { return "unknown" }
    return version
}

private func displayHost(_ targetURL: String) -> String {
    URLComponents(string: targetURL)?.host ?? targetURL
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private func stop(_ error: CLIError) throws -> Never {
    write(error.rendered, to: .standardError)
    throw ExitCode(error.exitCode)
}

private func write(_ text: String, to handle: FileHandle) {
    handle.write(Data(text.utf8))
}
