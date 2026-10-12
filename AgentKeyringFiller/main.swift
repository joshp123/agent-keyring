import AgentKeyringFillerSupport
import AppKit
import ApplicationServices
import Darwin
import Security
import OSLog

private let fillerLogger = Logger(subsystem: "com.agentkeyring.app", category: "FillerService")

final class FillerService: NSObject, AgentKeyringFillerProtocol {
    private var previousWindow: AXUIElement?
    private var previousFocusedElement: AXUIElement?
    private var windowIdentifier: String?
    private var focusedElementIdentifier: String?

    func inspect(withReply reply: @escaping (FillInspection) -> Void) {
        DispatchQueue.main.async {
            let inspection = self.inspectFrontmost()
            self.logInspectionRefusal(inspection)
            reply(inspection)
        }
    }

    func type(value: NSMutableData, expected: FillInspection, deadline: Date, withReply reply: @escaping (FillTypingResult) -> Void) {
        DispatchQueue.main.async {
            let result = FillerTypingOperation.type(value: value, expected: expected, deadline: deadline,
                inspect: self.inspectFrontmost, post: self.postUnicode)
            switch result {
            case .filled, .failed: break // Posting failures log their specific cause below.
            case .accessibilityMissing: fillerLogger.error("Typing refused: Accessibility permission missing.")
            case .screenLocked: fillerLogger.error("Typing refused: screen locked.")
            case .targetChanged: fillerLogger.error("Typing refused: browser, page or focused field changed.")
            case .requestExpired: fillerLogger.error("Typing refused: request deadline reached.")
            }
            reply(result)
        }
    }

    private func postUnicode(_ value: NSMutableData, deadline: Date) -> FillTypingResult {
        guard value.length > 0, value.length.isMultiple(of: MemoryLayout<UniChar>.size) else {
            fillerLogger.error("Typing failed: empty or invalid Unicode buffer.")
            return .failed
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
            fillerLogger.error("Typing failed: keyboard events could not be created.")
            return .failed
        }
        let units = value.mutableBytes.assumingMemoryBound(to: UniChar.self)
        let count = value.length / MemoryLayout<UniChar>.size
        var offset = 0
        while offset < count {
            // One Unicode scalar per event, including paired UTF-16 surrogates.
            let pairedSurrogate = (0xD800...0xDBFF).contains(units[offset]) && offset + 1 < count
                && (0xDC00...0xDFFF).contains(units[offset + 1])
            let length = pairedSurrogate ? 2 : 1
            for event in [down, up] {
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: length, unicodeString: units + offset)
                defer {
                    var empty: UniChar = 0
                    event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &empty)
                }
                guard Date() < deadline else { return .requestExpired }
                event.post(tap: .cghidEventTap)
            }
            offset += length
        }
        return .filled
    }

    private func logInspectionRefusal(_ inspection: FillInspection) {
        if inspection.screenLocked { fillerLogger.error("Inspection refused: screen locked.") }
        else if !inspection.accessibilityTrusted { fillerLogger.error("Inspection refused: Accessibility permission missing.") }
        else if inspection.bundleIdentifier == nil { fillerLogger.error("Inspection failed: no frontmost application.") }
        else if inspection.windowIdentifier == nil { fillerLogger.error("Inspection failed: no focused window.") }
        else if inspection.focusedElementIdentifier == nil { fillerLogger.error("Inspection refused: no focused element.") }
        else if inspection.pageAddress == nil { fillerLogger.error("Inspection refused: focused element has no readable web-area address.") }
        else if inspection.focusedRole == nil { fillerLogger.error("Inspection failed: focused element role unreadable.") }
    }

    private func inspectFrontmost() -> FillInspection {
        let application = NSWorkspace.shared.frontmostApplication
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session == nil || (session?["CGSSessionScreenIsLocked"] as? Bool ?? false)
        let trusted = AXIsProcessTrusted()
        let appElement = application.map { AXUIElementCreateApplication($0.processIdentifier) }
        let window = trusted ? appElement.flatMap { element($0, kAXFocusedWindowAttribute) } : nil
        let focused = trusted ? appElement.flatMap { element($0, kAXFocusedUIElementAttribute) } : nil
        if !sameElement(window, previousWindow) { windowIdentifier = window.map { _ in UUID().uuidString } }
        if !sameElement(focused, previousFocusedElement) { focusedElementIdentifier = focused.map { _ in UUID().uuidString } }
        previousWindow = window
        previousFocusedElement = focused
        return FillInspection(bundleIdentifier: application?.bundleIdentifier,
            processIdentifier: application?.processIdentifier ?? 0, screenLocked: locked,
            accessibilityTrusted: trusted, pageAddress: window.flatMap { pageAddress(window: $0, focused: focused) },
            focusedRole: focused.flatMap { string($0, kAXRoleAttribute) },
            focusedSubrole: focused.flatMap { string($0, kAXSubroleAttribute) },
            windowIdentifier: windowIdentifier, focusedElementIdentifier: focusedElementIdentifier)
    }

    private func sameElement(_ first: AXUIElement?, _ second: AXUIElement?) -> Bool {
        guard let first, let second else { return first == nil && second == nil }
        return CFEqual(first, second)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        let value = attribute(element, name)
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    private func pageAddress(window: AXUIElement, focused: AXUIElement?) -> String? {
        // Only the focused field's nearest web area can establish its page.
        var ancestor = focused
        for _ in 0..<64 {
            guard let current = ancestor else { break }
            if string(current, kAXRoleAttribute) == "AXWebArea" {
                return string(current, kAXURLAttribute)
            }
            if CFEqual(current, window) { break }
            ancestor = element(current, kAXParentAttribute)
        }
        return nil
    }
}

final class FillerListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Authenticate against the containing app's designated signing requirement.
        let hostURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var hostCode: SecStaticCode?
        var hostRequirement: SecRequirement?
        var requirementText: CFString?
        guard SecStaticCodeCreateWithPath(hostURL as CFURL, [], &hostCode) == errSecSuccess,
            let hostCode,
            SecCodeCopyDesignatedRequirement(hostCode, [], &hostRequirement) == errSecSuccess,
            let hostRequirement,
            SecRequirementCopyString(hostRequirement, [], &requirementText) == errSecSuccess,
            let requirementText
        else {
            fillerLogger.error("Connection refused: containing app signing requirement unavailable.")
            return false
        }
        connection.setCodeSigningRequirement(requirementText as String)
        connection.exportedInterface = fillerInterface()
        connection.exportedObject = FillerService()
        connection.resume()
        return true
    }
}

let delegate = FillerListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
