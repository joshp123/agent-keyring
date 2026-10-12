import AgentKeyringFeature
import AgentKeyringFillerSupport
import Foundation

@MainActor
public final class FakeCredentialFiller: CredentialFiller {
    public var inspection: FillInspection
    public var result: FillTypingResult = .filled
    public var onInspect: (() async -> Void)?
    public private(set) var inspectCount = 0
    public private(set) var typedValues: [String] = []
    public private(set) var typingDeadline: Date?
    public private(set) var expectedInspection: FillInspection?
    public private(set) var receivedBytes: NSMutableData?

    public init(inspection: FillInspection = fillInspection()) { self.inspection = inspection }

    public func inspect() async throws -> FillInspection {
        inspectCount += 1
        await onInspect?()
        return inspection
    }

    public func type(value: NSMutableData, expected: FillInspection, deadline: Date) async throws -> FillTypingResult {
        typingDeadline = deadline
        receivedBytes = value
        expectedInspection = expected
        typedValues.append(String(utf16CodeUnits: value.bytes.assumingMemoryBound(to: UInt16.self), count: value.length / 2))
        return result
    }
}

public func fillInspection(bundleIdentifier: String? = "com.apple.Safari", processIdentifier: Int32 = 123,
    screenLocked: Bool = false, accessibilityTrusted: Bool = true, pageAddress: String? = "https://example.com/login",
    focusedRole: String? = "AXTextField", focusedSubrole: String? = "AXSecureTextField",
    windowIdentifier: String? = "window-1", focusedElementIdentifier: String? = "field-1", browserSignatureTrusted: Bool = true) -> FillInspection {
    FillInspection(bundleIdentifier: bundleIdentifier, processIdentifier: processIdentifier,
        screenLocked: screenLocked, accessibilityTrusted: accessibilityTrusted, pageAddress: pageAddress,
        focusedRole: focusedRole, focusedSubrole: focusedSubrole,
        windowIdentifier: windowIdentifier, focusedElementIdentifier: focusedElementIdentifier, browserSignatureTrusted: browserSignatureTrusted)
}

@MainActor
public struct FillTestFixture {
    public static let password = "fill-canary-🐦-a-long-value-that-must-never-reach-the-agent"
    public static let username = "fill-user-canary@example.com"
    public let bridge: AgentBridgeDirectory
    public let generation: MirrorGeneration
    public let accessControl: CredentialAccessController
    public let grants: CredentialApprovalGrants
    public let filler: FakeCredentialFiller
    public let processor: AgentCredentialReleaseProcessor
    public let now: () -> Date

    public init(policy: CredentialAccessPolicy = .allowAutomatically,
        filler: FakeCredentialFiller = FakeCredentialFiller(), now: @escaping () -> Date = Date.init) throws {
        self.filler = filler
        self.now = now
        bridge = AgentBridgeDirectory(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try bridge.prepare()
        let id = UUID()
        let policyURL = bridge.rootURL.appendingPathComponent("policies.json")
        // Fixture signatures use only synthetic records and never access Keychain.
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1,
            "records": [["credentialID": id.uuidString, "policy": policy.rawValue]]])
        let signer = FakeAccessRulesSigner(signedBytes: bytes)
        let store = CredentialAccessPolicyStore(fileURL: policyURL, signer: signer)
        try bytes.write(to: policyURL)
        try signer.signature(for: bytes).write(to: policyURL.appendingPathExtension("signature"))
        accessControl = CredentialAccessController(store: store)
        grants = CredentialApprovalGrants(now: now)
        processor = AgentCredentialReleaseProcessor(accessControl: accessControl,
            grants: grants, approvals: CredentialApprovalCoordinator(lockState: UnlockedFillSession(), now: now),
            filler: filler, now: now)
        let item = MirrorItem(id: id,
            sourceIdentity: MirrorSourceIdentity(exporterIdentifier: "fill-test", accountID: Data(), itemID: Data()),
            title: "Synthetic fill login", origins: ["https://example.com"],
            credentials: [.password(userName: Self.username, password: Self.password),
                .totp(secret: Data("12345678901234567890".utf8), period: 30, digits: 8,
                    userName: Self.username, algorithm: .sha1, issuer: nil)])
        generation = MirrorGeneration(id: UUID(), previousGenerationID: nil, createdAt: now(), sourceExportedAt: now(),
            scope: .full, exporterIdentifier: "fill-test", exporterDisplayName: "Fill fixture", items: [item], skippedCredentialCount: 0)
    }

    public func request(field: AgentCredentialField = .password, targetURL: String = "https://example.com") throws -> AgentBridgeRequest {
        let request = AgentBridgeRequest(createdAt: now(), action: .fill, targetURL: targetURL, field: field)
        return request
    }

    public func cleanUp() { try? FileManager.default.removeItem(at: bridge.rootURL) }
}

private struct UnlockedFillSession: CredentialSessionLockState { var isLocked: Bool { false } }

/// Synthetic attribution for isolated policy tests. Never used by the app listener.
public let syntheticRequester = AgentRequester(name: "Fixture agent", processIdentifier: 100,
    processStartTime: HarnessProcessStartTime(seconds: 1_000, microseconds: 123),
    workingDirectory: "/tmp", machineName: "Fixture Mac", networkAddress: "192.0.2.1")
