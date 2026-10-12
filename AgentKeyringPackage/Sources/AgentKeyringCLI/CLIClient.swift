import AgentKeyringFeature
import ArgumentParser
import Foundation

enum CLIClient {
    @MainActor
    static func run(
        _ command: CLICommand,
        output: FileHandle = .standardOutput,
        diagnostics: FileHandle = .standardError,
        now: () -> Date = Date.init,
        sendRequest: ((AgentBridgeRequest) async throws -> AgentBridgeResponse)? = nil
    ) async throws {
        var failedFindMirror: AgentMirrorSummary?
        do {
            let request = command.request
            let response: AgentBridgeResponse
            if let sendRequest { response = try await sendRequest(request) }
            else { response = try await send(request, diagnostics: diagnostics) }
            guard response.ok else {
                if case .find = command { failedFindMirror = response.mirror }
                throw CLIError(response: response, command: command)
            }
            write(try CLIOutput.render(response, for: command), to: output)
            if (request.action == .acquire || request.action == .fill), response.approvalProgress?.askedAt != nil {
                if response.approvalProgress?.approvedOn == .iPhone {
                    write("Approved on the iPhone at \(approvalTime(response.approvalProgress?.approvedAt ?? now())).\n", to: diagnostics)
                } else if response.approvalProgress?.approvedOn == .mac {
                    write("Approved on the Mac at \(approvalTime(response.approvalProgress?.approvedAt ?? now())).\n", to: diagnostics)
                } else {
                    write("Approved at \(approvalTime(now())).\n", to: diagnostics)
                }
            }
        } catch let error as CLIError {
            write(error.rendered, to: diagnostics)
            if let mirror = failedFindMirror { write(CLIOutput.mirrorAge(mirror), to: diagnostics) }
            throw ExitCode(error.exitCode)
        } catch let failure as AgentBridgeFailure {
            try stop(CLIError(response: AgentBridgeResponse(id: UUID(), ok: false,
                error: failure.code, message: failure.message), command: command), diagnostics: diagnostics)
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

    @MainActor
    static func send(
        _ request: AgentBridgeRequest,
        diagnostics: FileHandle? = nil,
        waitUntil: Date? = nil,
        client: AgentBridgeClient = AgentBridgeClient(),
        launch: (@Sendable (UUID) async throws -> Void)? = nil
    ) async throws -> AgentBridgeResponse {
        let statusLines = CLIApprovalStatusLines(diagnostics: diagnostics)
        return try await client.send(request, waitUntil: waitUntil, onStatus: statusLines.receive) { id in
            if let launch { try await launch(id) }
            else { try await launchApp(id, deadline: waitUntil ?? request.expiresAt) }
        }
    }

    private static func launchApp(_ requestID: UUID, deadline: Date) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-g", "-b", AgentBridgeDirectory.applicationBundleIdentifier,
            "agentkeyring://agent/\(requestID.uuidString)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        while process.isRunning {
            guard Date() < deadline else {
                process.terminate()
                throw AgentBridgeFailure(.bridgeUnavailable, "Agent Keyring could not be opened.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard process.terminationStatus == 0 else {
            throw AgentBridgeFailure(.bridgeUnavailable, "Agent Keyring could not be opened.")
        }
    }
}
