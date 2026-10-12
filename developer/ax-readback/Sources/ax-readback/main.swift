import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &result)
    return error == .success ? result : nil
}

func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let result = attribute(element, name),
          CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
    return (result as! AXUIElement)
}

func textAttribute(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? "unavailable"
}

func printAddressCandidates(in window: AXUIElement) {
    var pending = [window]
    var visited: Set<AXUIElement> = []
    var candidateCount = 0
    while let element = pending.popLast() {
        guard visited.insert(element).inserted else { continue }
        if visited.count > 10_000 {
            print("Address traversal: truncated after 10,000 elements")
            break
        }
        var attributeNames: CFArray?
        AXUIElementCopyAttributeNames(element, &attributeNames)
        let names = Set((attributeNames as? [String] ?? []) + ["AXURL", "AXDocument"])
        for name in names.sorted() {
            // Never request AXValue or other field-value attributes.
            guard !name.localizedCaseInsensitiveContains("value"),
                  ["url", "document", "address"].contains(where: {
                      name.localizedCaseInsensitiveContains($0)
                  }), let result = attribute(element, name) else { continue }
            let candidates: [String]
            if let url = result as? URL { candidates = [url.absoluteString] }
            else if let string = result as? String { candidates = [string] }
            else if let urls = result as? [URL] { candidates = urls.map(\.absoluteString) }
            else if let strings = result as? [String] { candidates = strings }
            else { continue }
            for candidate in candidates where URL(string: candidate)?.scheme != nil {
                print("Page address [\(name), \(textAttribute(element, "AXRole")), element \(visited.count)]: \(candidate)")
                candidateCount += 1
            }
        }
        for relationship in ["AXChildren", "AXContents"] {
            if let children = attribute(element, relationship) as? [AXUIElement] {
                pending.append(contentsOf: children.reversed())
            }
        }
    }
    if candidateCount == 0 { print("Page address candidates: none exposed") }
}

func printSnapshot() {
    print("--- \(ISO8601DateFormatter().string(from: Date())) ---")
    print("Accessibility trusted: \(AXIsProcessTrusted())")
    guard let application = NSWorkspace.shared.frontmostApplication else {
        print("Frontmost app bundle ID: unavailable")
        print("Focused window title: unavailable")
        print("Page address candidates: unavailable")
        print("Focused element role: unavailable")
        print("Focused element subrole: unavailable")
        print("Secure text field: unknown")
        return
    }
    print("Frontmost app bundle ID: \(application.bundleIdentifier ?? "unavailable")")
    let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
    AXUIElementSetMessagingTimeout(applicationElement, 0.5)
    if let window = elementAttribute(applicationElement, "AXFocusedWindow") {
        print("Focused window title: \(textAttribute(window, "AXTitle"))")
        printAddressCandidates(in: window)
    } else {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(applicationElement, "AXFocusedWindow" as CFString, &result)
        print("Focused window title: unavailable (AX error \(error.rawValue))")
        print("Page address candidates: unavailable")
    }
    if let focused = elementAttribute(applicationElement, "AXFocusedUIElement") {
        let role = textAttribute(focused, "AXRole")
        let subrole = textAttribute(focused, "AXSubrole")
        print("Focused element role: \(role)")
        print("Focused element subrole: \(subrole)")
        print("Secure text field: \(role == "AXSecureTextField" || subrole == "AXSecureTextField")")
    } else {
        print("Focused element role: unavailable")
        print("Focused element subrole: unavailable")
        print("Secure text field: unknown")
    }
    fflush(stdout)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.isEmpty || arguments == ["--watch"] else {
    print("Usage: ax-readback [--watch]")
    exit(2)
}
printSnapshot()
if arguments == ["--watch"] {
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in printSnapshot() }
    RunLoop.main.run()
}
