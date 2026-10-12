import AgentKeyringFillerSupport
import AgentKeyringTestSupport
import Foundation
import Testing

@Suite("Helper re-inspection before typing")
struct FillerRecheckTests {
    @Test("Changed or unavailable targets never post events and always zero the value", arguments: [
        "unchanged", "locked", "permission", "app", "process", "page", "window", "field", "role", "subrole", "unreadable", "unfocused",
    ])
    func recheck(path: String) throws {
        let expected = fillInspection()
        let current = switch path {
        case "locked": fillInspection(screenLocked: true)
        case "permission": fillInspection(accessibilityTrusted: false)
        case "app": fillInspection(bundleIdentifier: "com.google.Chrome")
        case "process": fillInspection(processIdentifier: 456)
        case "page": fillInspection(pageAddress: "https://example.com/other-page")
        case "window": fillInspection(windowIdentifier: "window-2")
        case "field": fillInspection(focusedElementIdentifier: "field-2")
        case "role": fillInspection(focusedRole: "AXTextArea")
        case "subrole": fillInspection(focusedSubrole: nil)
        case "unreadable": fillInspection(pageAddress: nil)
        case "unfocused": fillInspection(focusedElementIdentifier: nil)
        default: fillInspection()
        }
        let value = NSMutableData(data: Data("synthetic-typing-canary".utf8))
        var inspections = 0
        var posts = 0
        let result = FillerTypingOperation.type(value: value, expected: expected, inspect: {
            inspections += 1
            return current
        }, post: { bytes in
            #expect(inspections == 1)
            #expect(String(decoding: bytes as Data, as: UTF8.self) == "synthetic-typing-canary")
            posts += 1
            return true
        })
        let expectedResult: FillTypingResult = switch path {
        case "unchanged": .filled
        case "locked": .screenLocked
        case "permission": .accessibilityMissing
        default: .targetChanged
        }
        #expect(result == expectedResult)
        #expect(posts == (path == "unchanged" ? 1 : 0))
        #expect((value as Data).allSatisfy { $0 == 0 })
    }

    @Test("Failed posting zeroes the value")
    func failedPosting() {
        let value = NSMutableData(data: Data("synthetic".utf8))
        #expect(FillerTypingOperation.type(value: value, expected: fillInspection(),
            inspect: { fillInspection() }, post: { _ in false }) == .failed)
        #expect((value as Data).allSatisfy { $0 == 0 })
    }

    @Test("The typed XPC inspection survives secure coding")
    func secureCoding() throws {
        let inspection = fillInspection()
        let bytes = try NSKeyedArchiver.archivedData(withRootObject: inspection, requiringSecureCoding: true)
        let decoded = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: FillInspection.self, from: bytes))
        #expect(decoded.typingRefusal(comparedTo: inspection) == nil)
    }
}
