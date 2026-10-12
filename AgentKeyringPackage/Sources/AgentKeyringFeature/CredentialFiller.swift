import AgentKeyringFillerSupport
import Darwin
import Foundation
import OSLog

private let fillerClientLogger = Logger(subsystem: "com.agentkeyring.app", category: "FillerClient")

@MainActor
public protocol CredentialFiller {
    func inspect() async throws -> FillInspection
    func type(value: NSMutableData, expected: FillInspection, deadline: Date) async throws -> FillTypingResult
}

@MainActor
public final class XPCCredentialFiller: CredentialFiller {
    private let connection: NSXPCConnection

    public init() {
        let hostIdentifier = Bundle.main.bundleIdentifier ?? "com.example.AgentKeyring"
        connection = NSXPCConnection(serviceName: hostIdentifier + ".Filler")
        connection.remoteObjectInterface = fillerInterface()
        connection.resume()
    }

    isolated deinit { connection.invalidate() }

    public func inspect() async throws -> FillInspection {
        try await call { proxy, completion in proxy.inspect { completion(.success($0)) } }
    }

    public func type(value: NSMutableData, expected: FillInspection, deadline: Date) async throws -> FillTypingResult {
        let result: FillTypingResult = try await call { proxy, completion in
            proxy.type(value: value, expected: expected, deadline: deadline) { completion(.success($0)) }
        }
        switch result {
        case .filled: break
        case .accessibilityMissing: fillerClientLogger.error("Fill refused: Accessibility permission missing.")
        case .screenLocked: fillerClientLogger.error("Fill refused: screen locked.")
        case .targetChanged: fillerClientLogger.error("Fill refused: browser, page or focused field changed.")
        case .requestExpired: fillerClientLogger.error("Fill refused: request deadline reached.")
        case .failed: fillerClientLogger.error("Fill failed: helper could not post keyboard events.")
        }
        return result
    }

    private func call<Result: Sendable>(
        _ invoke: (AgentKeyringFillerProtocol, @escaping @Sendable (Swift.Result<Result, Error>) -> Void) -> Void
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let reply = FillerReply(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in reply.finish(.failure(Self.unavailable)) })
                as? AgentKeyringFillerProtocol else {
                reply.finish(.failure(Self.unavailable))
                return
            }
            invoke(proxy, reply.finish)
        }
    }

    nonisolated private static var unavailable: AgentBridgeFailure {
        AgentBridgeFailure(.bridgeUnavailable, "Agent Keyring's fill service could not be reached.")
    }
}

private final class FillerReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        if pending != nil, case .failure = result { fillerClientLogger.error("Fill service request failed: XPC unavailable.") }
        pending?.resume(with: result)
    }
}

@MainActor
struct AgentCredentialFillProcessor {
    let filler: any CredentialFiller
    let resolver: CredentialResolver

    func fill(candidate: CredentialCandidate, requestedURL: String, field: AgentCredentialField, deadline: Date,
        value: () async throws -> String) async throws {
        let inspection = try await filler.inspect()
        try validate(inspection, candidate: candidate, requestedURL: requestedURL, field: field)
        let secret = try await value()
        let bytes = NSMutableData(length: secret.utf16.count * MemoryLayout<UniChar>.size)!
        defer { _ = memset_s(bytes.mutableBytes, bytes.length, 0, bytes.length) }
        let units = bytes.mutableBytes.assumingMemoryBound(to: UniChar.self)
        for (index, unit) in secret.utf16.enumerated() { units[index] = unit }
        switch try await filler.type(value: bytes, expected: inspection, deadline: deadline) {
        case .filled: return
        case .accessibilityMissing: throw AgentBridgeFailure(.accessibilityMissing, Self.accessibilityMessage)
        case .screenLocked: throw AgentBridgeFailure(.screenLocked, "The screen is locked.")
        case .targetChanged:
            throw AgentBridgeFailure(.fillTargetChanged, "The browser, page or focused field changed; focus the field and retry.")
        case .requestExpired: throw AgentBridgeFailure(.requestExpired, "The fill request expired before typing completed.")
        case .failed: throw AgentBridgeFailure(.internalError, "Agent Keyring could not type into the focused field.")
        }
    }

    static let accessibilityMessage = "Grant Agent Keyring Accessibility in System Settings → Privacy & Security → Accessibility."

    func validate(_ inspection: FillInspection, candidate: CredentialCandidate, requestedURL: String,
        field: AgentCredentialField) throws {
        do { try validateDestination(inspection, candidate: candidate, requestedURL: requestedURL, field: field) }
        catch let failure as AgentBridgeFailure {
            fillerClientLogger.error("Fill validation refused: \(failure.code.rawValue, privacy: .public).")
            throw failure
        } catch let failure as CredentialResolverError {
            fillerClientLogger.error("Fill validation refused: \(failure.rawValue, privacy: .public).")
            throw failure
        }
    }

    private func validateDestination(_ inspection: FillInspection, candidate: CredentialCandidate, requestedURL: String,
        field: AgentCredentialField) throws {
        if inspection.screenLocked { throw AgentBridgeFailure(.screenLocked, "The screen is locked.") }
        if !inspection.accessibilityTrusted { throw AgentBridgeFailure(.accessibilityMissing, Self.accessibilityMessage) }
        guard Self.supportedBundleIdentifiers.contains(inspection.bundleIdentifier ?? "") else {
            throw AgentBridgeFailure(.unsupportedBrowser, "This browser is not supported; use agent-browser.")
        }
        guard let pageAddress = inspection.pageAddress,
            let pageHost = resolver.host(of: pageAddress) else {
            throw AgentBridgeFailure(.unreadablePageAddress, "This browser's page address cannot be read; use agent-browser.")
        }
        let savedOrigin = try resolver.savedOrigin(for: candidate, requestedURL: requestedURL)
        let savedHost = resolver.host(of: savedOrigin)!
        guard resolver.hostMatches(stored: savedHost, target: pageHost) else {
            throw AgentBridgeFailure(.pageMismatch, "The page host \(pageHost) does not match the saved site \(savedHost).")
        }
        try resolver.validateSecureTarget(pageAddress)
        let secure = inspection.focusedRole == "AXSecureTextField" || inspection.focusedSubrole == "AXSecureTextField"
        let textField = inspection.focusedRole == "AXTextField" || inspection.focusedRole == "AXSecureTextField"
        guard textField, secure == (field == .password),
            inspection.focusedElementIdentifier != nil, inspection.windowIdentifier != nil else {
            throw AgentBridgeFailure(.wrongFocusedField,
                field == .password ? "Focus a secure password field, then retry." : "Focus a non-secure text field, then retry.")
        }
    }

    private static let supportedBundleIdentifiers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.anthropic.claudefordesktop", "com.openai.codex",
    ]
}
