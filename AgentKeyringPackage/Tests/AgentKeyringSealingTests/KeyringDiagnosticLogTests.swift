// Written by AI on 2026.11.20 by model Claude Opus 5.5; writers on many threads on 2026.11.28 by model claude opus 5.5.
// The devices' log: a ring that keeps the newest 500, the Watch's lines added
// on the iPhone once each, and no line lost or torn when many threads write.

@testable import AgentKeyringSealing
import Foundation
import Testing

struct KeyringDiagnosticLogTests {
    @Test func theRingKeepsTheNewestAndTheWatchsLinesOnce() throws {
        let file = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let log = KeyringDiagnosticLog(device: "iphone", file: file)
        for n in 0..<700 { log.noteDeviceEvent("test", "line", ["n": "\(n)"]) }
        let kept = log.lines(last: .max)
        #expect(kept.count <= KeyringDiagnosticLog.keep + KeyringDiagnosticLog.keep / 5)
        #expect(kept.last?.hasSuffix("n=699") == true)
        let watch = ["1970-01-01T00:00:00.000Z watch answer sent request=r1"]
        log.mergeLogLines(watch); log.mergeLogLines(watch)
        #expect(log.lines(last: .max).filter { $0 == watch[0] }.count == 1)
    }

    #if os(macOS)
    @Test("On a Mac, where they run only in tests, the iPhone's and the Watch's rings stay in memory")
    func iPhoneAndWatchRingsStayOffTheMacsDisk() {
        #expect(KeyringDiagnosticLog.defaultFile == nil)
        for log in [KeyringDiagnosticLog.iPhone, .watch] {
            let request = UUID().uuidString
            log.noteDeviceEvent("test", "line", ["request": request])
            #expect(log.lines(since: 0, request: request).count == 1)
        }
    }
    #endif

    @Test func linesWrittenFromManyThreadsAtOnceAreAllInTheFileWhole() async throws {
        let file = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let log = KeyringDiagnosticLog(device: "watch", file: file)
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<8 {
                group.addTask { for n in 0..<50 { log.noteDeviceEvent("test", "line", ["writer": "\(writer)", "n": "\(n)"]) } }
            }
        }
        let written = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(written.count == 400)
        #expect(written.allSatisfy { $0.contains(" watch test line writer=") && $0.contains(" n=") })
        #expect(Set(written).count == 400)
    }
}
