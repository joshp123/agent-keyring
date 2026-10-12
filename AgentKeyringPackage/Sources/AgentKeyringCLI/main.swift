import AgentKeyringFeature
import ArgumentParser
import Darwin
import Foundation

@main
struct AgentKeyringCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-keyring",
        abstract:
            "Use imported Apple Passwords logins from the command line.",
        discussion: """
            EXAMPLES
              agent-keyring find example.com
              agent-keyring acquire password example.com
              agent-keyring read REFERENCE
              agent-keyring clear REFERENCE
            """,
        version: installedVersion(),
        subcommands: [Find.self, Acquire.self, Read.self, Clear.self, Copy.self, Status.self, Install.self]
    )

    mutating func run() {
        print(
            "Agent Keyring lets local agents use imported Apple Passwords logins."
        )
        print("")
        print("Try:")
        print("  agent-keyring find example.com")
        print("  agent-keyring acquire password example.com")
        print("")
        print("Run 'agent-keyring --help' for all commands.")
    }
}

struct Find: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show logins that match a site without requesting a secret."
    )

    @Argument(help: "The site or page URL, such as example.com.")
    var site: String

    @Option(help: "Only show this account.")
    var account: String?

    func validate() throws {
        _ = try normaliseWebTarget(site)
    }

    mutating func run() async throws {
        try await CLIClient.run(
            .find(targetURL: normaliseWebTarget(site), account: account)
        )
    }
}

struct Copy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy one credential field without printing it."
    )

    @Argument(help: "The field to copy: username, password or code.")
    var field: CredentialFieldArgument

    @Argument(help: "The site or page URL, such as example.com.")
    var site: String

    @Option(help: "Choose an account when several logins match.")
    var account: String?

    @Option(help: "Choose between duplicate account entries. Find shows the ID when needed.")
    var credential: String?

    @Option(help: "Clear the clipboard after this many seconds (5–120).")
    var expires = 30

    func validate() throws {
        _ = try normaliseSecureWebTarget(site)
        guard (5...120).contains(expires) else {
            throw ValidationError("--expires must be between 5 and 120 seconds.")
        }
        if let credential, UUID(uuidString: credential) == nil {
            throw ValidationError(
                "'\(credential)' is not a valid credential ID. Run 'agent-keyring find \(site)' to see matching logins."
            )
        }
    }

    mutating func run() async throws {
        try await CLIClient.run(
            .copy(
                field: field.bridgeField,
                targetURL: normaliseSecureWebTarget(site),
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

struct Acquire: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Retain one credential field for 5 minutes; print its reference.",
        discussion: "Clear the reference when entry succeeds or you abandon the task. Values expire after 5 minutes."
    )

    @Argument(help: "The field to acquire: username, password or code.") var field: CredentialFieldArgument
    @Argument(help: "The site or page URL, such as example.com.") var site: String
    @Option(help: "Choose an account when several logins match.") var account: String?
    @Option(help: "Choose a credential ID shown by find.") var credential: String?

    func validate() throws {
        _ = try normaliseSecureWebTarget(site)
        guard account == nil || credential == nil else {
            throw ValidationError("Choose either --account or --credential.")
        }
        if let credential, UUID(uuidString: credential) == nil {
            throw ValidationError("A valid credential ID is required.")
        }
    }

    mutating func run() async throws {
        try await CLIClient.run(.acquire(
            field: field.bridgeField, targetURL: normaliseSecureWebTarget(site),
            account: account, credentialID: credential.flatMap(UUID.init(uuidString:))
        ))
    }
}

struct Read: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write a retained value to stdout without consuming it or adding a newline."
    )

    @Argument(help: "The reference printed by acquire.") var reference: String

    func validate() throws { _ = try credentialReference(reference) }

    mutating func run() async throws {
        try await CLIClient.read(reference: credentialReference(reference))
    }
}

struct Clear: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Clear a retained value. An already cleared reference is harmless."
    )

    @Argument(help: "The reference printed by acquire.") var reference: String

    func validate() throws { _ = try credentialReference(reference) }

    mutating func run() async throws {
        try await CLIClient.clear(reference: credentialReference(reference))
    }
}

private func credentialReference(_ value: String) throws -> UUID {
    guard let reference = UUID(uuidString: value) else {
        throw ValidationError("Use a valid reference printed by acquire.")
    }
    return reference
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

enum CredentialFieldArgument: String, CaseIterable, ExpressibleByArgument {
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
    case acquire(field: AgentCredentialField, targetURL: String, account: String?, credentialID: UUID?)
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
        case let .acquire(field, targetURL, account, credentialID):
            AgentBridgeRequest(
                action: .acquire, targetURL: targetURL, usernameHint: account,
                candidateID: credentialID, field: field
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
    @MainActor
    static func run(
        _ command: CLICommand,
        output: FileHandle = .standardOutput,
        diagnostics: FileHandle = .standardError,
        sendRequest: (AgentBridgeRequest) async throws -> AgentBridgeResponse = send
    ) async throws {
        do {
            if case let .copy(field, targetURL, _, _, _) = command {
                write(
                    "Requesting \(field.displayName) for \(displayHost(targetURL))…\n",
                    to: diagnostics
                )
            }
            let request = command.request
            let response = try await sendRequest(request)
            guard response.ok else {
                if case .find = command, let mirror = response.mirror {
                    write(CLIOutput.freshness(mirror), to: diagnostics)
                }
                throw CLIError(response: response, command: command)
            }
            write(try CLIOutput.render(response, for: command), to: output)
        } catch let error as CLIError {
            try stop(error, diagnostics: diagnostics)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code)
        {
            try stop(
                CLIError(
                    "This process cannot access Agent Keyring's local data.",
                    suggestion: "Allow access and try again."
                ), diagnostics: diagnostics
            )
        } catch {
            try stop(.unavailable, diagnostics: diagnostics)
        }
    }

    @MainActor
    static func read(
        reference: UUID,
        output: FileHandle = .standardOutput,
        diagnostics: FileHandle = .standardError
    ) throws {
        do {
            var bytes = try CredentialTransfer.read(requestID: reference)
            defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
            try output.write(contentsOf: bytes)
        } catch CredentialTransferError.unavailable {
            try stop(CLIError("No retained credential exists for this reference."), diagnostics: diagnostics)
        } catch {
            try stop(CLIError("Could not write the credential to standard output."), diagnostics: diagnostics)
        }
    }

    @MainActor
    static func clear(
        reference: UUID,
        diagnostics: FileHandle = .standardError
    ) throws {
        guard CredentialTransfer.clear(requestID: reference) else {
            try stop(
                CLIError(
                    "Could not confirm the credential buffer was cleared; its value may still be retained.",
                    suggestion: "Run clear through the shell used to acquire it."
                ), diagnostics: diagnostics
            )
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

    static func send(_ request: AgentBridgeRequest) async throws -> AgentBridgeResponse {
        try await AgentBridgeClient().send(request) { requestID in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [
                "-g", "-b", AgentBridgeDirectory.applicationBundleIdentifier,
                "agentkeyring://agent/\(requestID.uuidString)",
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw AgentBridgeFailure(.bridgeUnavailable, "Agent Keyring could not be opened.")
            }
        }
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
            "Use imported Apple Passwords logins from the command line.",
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
        case .acquire: return response.id.uuidString + "\n"
        case .status:
            guard let mirror = response.mirror else { throw CLIError.invalidResponse }
            let noun = mirror.credentialCount == 1 ? "login" : "logins"
            return
                "\(mirror.credentialCount) \(noun) available\n" + freshness(mirror)
        case let .find(targetURL, _):
            guard let candidates = response.candidates else { throw CLIError.invalidResponse }
            guard let mirror = response.mirror else { throw CLIError.invalidResponse }
            return renderCandidates(candidates, targetURL: targetURL) + freshness(mirror)
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
            if accountCounts[candidate.username?.lowercased() ?? "", default: 0] > 1 {
                lines.append("  Credential ID: \(candidate.id.uuidString)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func freshness(_ mirror: AgentMirrorSummary) -> String {
        let warning = mirror.ageSeconds > 7 * 86_400
            ? "Warning: the mirror is older than 7 days. Update it from Apple Passwords.\n" : ""
        return "Updated \(age(mirror.ageSeconds))\n" + warning
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
                    "Run 'agent-keyring find \(targetURL)' to see the credential IDs, then choose one:\nagent-keyring \(command.releaseVerb) \(command.fieldArgument) \(shellQuote(targetURL)) --credential UUID"
            } else if let account = accounts.first {
                suggestion =
                    "Choose an account:\n\(choices)\nTry: agent-keyring \(command.releaseVerb) \(command.fieldArgument) \(shellQuote(targetURL)) --account \(shellQuote(account))"
            } else {
                suggestion = "Run 'agent-keyring find \(targetURL)' and choose a credential."
            }
            self.init(
                "More than one login matches \(displayHost(targetURL)).",
                suggestion: suggestion
            )
        case .fieldUnavailable:
            self.init("That login has no \(command.fieldName) available.")
        case .insecureOrigin:
            self.init(
                "Agent Keyring will not release credentials to an insecure page.",
                suggestion: "Use the HTTPS page instead."
            )
        case .invalidURL:
            self.init(
                "'\(targetURL)' is not a valid site or page URL.",
                suggestion: "Use a site such as example.com."
            )
        case .mirrorUnavailable:
            self.init(
                "No logins are available yet.",
                suggestion: "Open Agent Keyring and import them from Apple Passwords."
            )
        case .authorizationDenied:
            self.init("The request was not approved. Nothing was released.")
        case .authorizationUnavailable:
            self.init(
                response.message ?? "Credential approval is not available. Nothing was released."
            )
        case .policyDenied:
            self.init("Access to this login is blocked in Agent Keyring. Nothing was released.")
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
    fileprivate var releaseVerb: String {
        if case .acquire = self { return "acquire" }
        return "copy"
    }

    fileprivate var targetURL: String {
        switch self {
        case let .find(targetURL, _), let .copy(_, targetURL, _, _, _), let .acquire(_, targetURL, _, _): targetURL
        case .status: "the requested site"
        }
    }

    fileprivate var fieldName: String {
        switch self {
        case let .copy(field, _, _, _, _), let .acquire(field, _, _, _): field.displayName
        default: "requested field"
        }
    }

    fileprivate var fieldArgument: String {
        switch self {
        case let .copy(field, _, _, _, _), let .acquire(field, _, _, _): field.argumentName
        default: "password"
        }
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

func normaliseWebTarget(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let target = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let components = URLComponents(string: target),
        let scheme = components.scheme?.lowercased(),
        scheme == "https" || scheme == "http",
        components.host?.isEmpty == false
    else {
        throw ValidationError(
            "'\(value)' is not a valid site or page URL. Use a site such as example.com."
        )
    }
    return target
}

func normaliseSecureWebTarget(_ value: String) throws -> String {
    let target = try normaliseWebTarget(value)
    guard let components = URLComponents(string: target),
        let host = components.host?.lowercased()
    else { return target }
    let localhost = host == "localhost" || host == "127.0.0.1" || host == "::1"
    guard components.scheme?.lowercased() == "https" || localhost else {
        throw ValidationError(
            "Agent Keyring will not release credentials to an insecure page. Use the HTTPS page instead."
        )
    }
    return target
}

func installedVersion(executable: URL? = currentExecutableURL()) -> String {
    guard let executable else { return "unknown" }
    let infoURL = executable.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: infoURL),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let dictionary = plist as? [String: Any],
        let version = dictionary["CFBundleShortVersionString"] as? String
    else { return "unknown" }
    return version
}

private func currentExecutableURL() -> URL? {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var path = [CChar](repeating: 0, count: Int(size))
    let result = path.withUnsafeMutableBufferPointer { buffer in
        _NSGetExecutablePath(buffer.baseAddress, &size)
    }
    guard result == 0 else { return nil }
    let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath()
}

private func displayHost(_ targetURL: String) -> String {
    URLComponents(string: targetURL)?.host ?? targetURL
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private func stop(_ error: CLIError, diagnostics: FileHandle = .standardError) throws -> Never {
    write(error.rendered, to: diagnostics)
    throw ExitCode(error.exitCode)
}

private func write(_ text: String, to handle: FileHandle) {
    handle.write(Data(text.utf8))
}
