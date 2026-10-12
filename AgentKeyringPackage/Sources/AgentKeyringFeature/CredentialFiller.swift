import AgentKeyringFillerSupport
import Darwin
import Foundation

@MainActor
public protocol CredentialFiller {
    func inspect() async throws -> FillInspection
    func type(value: NSMutableData, expected: FillInspection) async throws -> FillTypingResult
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

    public func type(value: NSMutableData, expected: FillInspection) async throws -> FillTypingResult {
        try await call { proxy, completion in
            proxy.type(value: value, expected: expected) { completion(.success($0)) }
        }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { reply.finish(.failure(Self.unavailable)) }
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
        pending?.resume(with: result)
    }
}

@MainActor
struct AgentCredentialFillProcessor {
    let filler: any CredentialFiller
    let resolver: CredentialResolver

    func fill(candidate: CredentialCandidate, requestedURL: String, field: AgentCredentialField,
        value: () async throws -> String) async throws {
        let inspection = try await filler.inspect()
        try validate(inspection, candidate: candidate, requestedURL: requestedURL, field: field)
        let secret = try await value()
        let bytes = NSMutableData(length: secret.utf16.count * MemoryLayout<UniChar>.size)!
        defer { _ = memset_s(bytes.mutableBytes, bytes.length, 0, bytes.length) }
        let units = bytes.mutableBytes.assumingMemoryBound(to: UniChar.self)
        for (index, unit) in secret.utf16.enumerated() { units[index] = unit }
        switch try await filler.type(value: bytes, expected: inspection) {
        case .filled: return
        case .accessibilityMissing: throw AgentBridgeFailure(.accessibilityMissing, Self.accessibilityMessage)
        case .screenLocked: throw AgentBridgeFailure(.screenLocked, "The screen is locked.")
        case .targetChanged:
            throw AgentBridgeFailure(.fillTargetChanged, "The browser, page or focused field changed; focus the field and retry.")
        case .failed: throw AgentBridgeFailure(.internalError, "Agent Keyring could not type into the focused field.")
        }
    }

    static let accessibilityMessage = "Grant Agent Keyring Accessibility in System Settings → Privacy & Security → Accessibility."

    func validate(_ inspection: FillInspection, candidate: CredentialCandidate, requestedURL: String,
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
