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
        let result = FillerTypingOperation.type(value: value, expected: expected, deadline: Date().addingTimeInterval(60), inspect: {
            inspections += 1
            return current
        }, post: { bytes, _ in
            #expect(inspections == 1)
            #expect(String(decoding: bytes as Data, as: UTF8.self) == "synthetic-typing-canary")
            posts += 1
            return .filled
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
        #expect(FillerTypingOperation.type(value: value, expected: fillInspection(), deadline: Date().addingTimeInterval(60),
            inspect: { fillInspection() }, post: { _, _ in .failed }) == .failed)
        #expect((value as Data).allSatisfy { $0 == 0 })
    }

    @Test("Focus changes during posting are reported after typing", arguments: ["app", "page", "field"])
    func changesDuringPosting(path: String) {
        let expected = fillInspection()
        var current = expected
        let value = NSMutableData(data: Data("synthetic".utf8))
        var inspections = 0
        let result = FillerTypingOperation.type(value: value, expected: expected,
            deadline: Date().addingTimeInterval(60), inspect: { inspections += 1; return current }, post: { _, _ in
                current = switch path {
                case "app": fillInspection(bundleIdentifier: "com.google.Chrome")
                case "page": fillInspection(pageAddress: "https://other.invalid")
                default: fillInspection(focusedElementIdentifier: "other-field")
                }
                return .filled
            })
        #expect(result == .targetChanged && inspections == 2)
        #expect((value as Data).allSatisfy { $0 == 0 })
    }

    @Test("Expired fills never start posting", arguments: ["before-inspection", "during-inspection"])
    func deadlineBeforePosting(path: String) {
        let deadline = Date(timeIntervalSince1970: 100)
        var now = path == "before-inspection" ? deadline : deadline.addingTimeInterval(-1)
        let value = NSMutableData(data: Data("synthetic".utf8))
        let result = FillerTypingOperation.type(value: value, expected: fillInspection(), deadline: deadline,
            now: { now }, inspect: { now = deadline; return fillInspection() }, post: { _, _ in
                Issue.record("Expired fill posted")
                return .filled
            })
        #expect(result == .requestExpired)
        #expect((value as Data).allSatisfy { $0 == 0 })
    }

    @Test("The helper's posting deadline is preserved in its result")
    func deadlineDuringPosting() {
        let deadline = Date().addingTimeInterval(60)
        let result = FillerTypingOperation.type(value: NSMutableData(data: Data("synthetic".utf8)),
            expected: fillInspection(), deadline: deadline, inspect: { fillInspection() }, post: { _, receivedDeadline in
                #expect(receivedDeadline == deadline)
                return .requestExpired
            })
        #expect(result == .requestExpired)
    }

    @Test("The typed XPC inspection survives secure coding")
    func secureCoding() throws {
        let inspection = fillInspection()
        let bytes = try NSKeyedArchiver.archivedData(withRootObject: inspection, requiringSecureCoding: true)
        let decoded = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: FillInspection.self, from: bytes))
        #expect(decoded.typingRefusal(comparedTo: inspection) == nil)
    }
}
