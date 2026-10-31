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
