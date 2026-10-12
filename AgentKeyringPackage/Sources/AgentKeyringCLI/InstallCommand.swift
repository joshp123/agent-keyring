import AgentKeyringFeature
import ArgumentParser
import Foundation

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

extension CLIClient {
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
                source: executable
            ),
            IntegrationLink(
                destination: skillDestination,
                source: skillSource
            ),
        ]
        try IntegrationInstaller.install(integrations)
        return CLIInstallResult(
            commandPath: commandDestination.path,
            skillPath: skillDestination.path
        )
    }
}

struct IntegrationLink {
    let destination: URL
    let source: URL
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

        guard fileManager.fileExists(atPath: link.destination.path)
        else {
            return .missing
        }

        throw CLIError(
            "Cannot install because \(link.destination.path) already exists.",
            suggestion: "Move it, then run the install command again."
        )
    }
}

struct CLIInstallResult {
    let commandPath: String
    let skillPath: String
}
