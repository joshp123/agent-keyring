import AgentKeyringFeature
import ArgumentParser
import Foundation

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install the command, Claude Code and Codex skills, and agent-browser plugin."
    )

    mutating func run() throws {
        do {
            let result = try CLIClient.install()
            print(result.rendered, terminator: "")
        } catch let error as CLIError {
            try stop(error)
        } catch {
            try stop(.unavailable)
        }
    }
}

extension CLIClient {
    static func install(
        home: URL = ProcessInfo.processInfo.environment["HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser,
        executable: URL = URL(fileURLWithPath: CommandLine.arguments[0])
    ) throws -> CLIInstallResult {
        let fileManager = FileManager.default
        let executable = executable.standardizedFileURL
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

        let skillSource = contentsDirectory
            .appendingPathComponent("Resources/AgentTools/AgentSkill/agent-keyring/SKILL.md")
        guard fileManager.fileExists(atPath: skillSource.path) else {
            throw CLIError(
                "AgentKeyring.app is missing its agent skill.",
                suggestion: "Reinstall Agent Keyring, then try again."
            )
        }
        let skill = try Data(contentsOf: skillSource)
        let commandDestination = home.appendingPathComponent(".local/bin/agent-keyring")
        let configURL = home.appendingPathComponent(".agent-browser/config.json")
        let config = try AgentBrowserRegistration.mergedConfig(at: configURL, command: commandDestination.path)
        try IntegrationInstaller.install([
            IntegrationLink(destination: commandDestination, source: executable)
        ])
        var lines = ["Command: \(commandDestination.path)"]
        for harness in ["codex", "claude"] {
            let destination = home.appendingPathComponent(".\(harness)/skills/agent-keyring/SKILL.md")
            do {
                let directory = destination.deletingLastPathComponent()
                // Earlier releases linked the entire skill directory to the app bundle.
                if (try? fileManager.destinationOfSymbolicLink(atPath: directory.path)) != nil {
                    try fileManager.trashItem(at: directory, resultingItemURL: nil)
                }
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                if (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                    try fileManager.trashItem(at: destination, resultingItemURL: nil)
                }
                try skill.write(to: destination, options: .atomic)
                lines.append("Skill: \(destination.path)")
            } catch {
                lines.append("Skipped \(destination.path); add the bundled skill: \(skillSource.path)")
            }
        }
        try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try config.write(to: configURL, options: .atomic)
        lines.append("Plugin: \(configURL.path)")
        lines.append("AGENTS.md:")
        lines.append("Use agent-keyring for logins and secrets. See `agent-keyring --help`.")
        return CLIInstallResult(rendered: lines.joined(separator: "\n") + "\n")
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

enum AgentBrowserRegistration {
    static func mergedConfig(at url: URL, command: String) throws -> Data {
        var config: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw CLIError("Cannot register the plugin: \(url.path) must contain a JSON object.")
            }
            config = existing
        }
        var plugins: [[String: Any]] = []
        if let existing = config["plugins"] {
            guard let entries = existing as? [[String: Any]] else {
                throw CLIError("Cannot register the plugin: plugins in \(url.path) must be an array of objects.")
            }
            plugins = entries
        }
        let registration: [String: Any] = [
            "name": "agent-keyring", "command": command,
            "args": ["agent-browser-plugin"], "capabilities": ["credential.read"],
        ]
        if let index = plugins.firstIndex(where: { $0["name"] as? String == "agent-keyring" }) {
            plugins[index].merge(registration) { _, installed in installed }
        } else {
            plugins.append(registration)
        }
        config["plugins"] = plugins
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }
}

struct CLIInstallResult {
    let rendered: String
}
