// Written by AI on 2026.11.20 by model Claude Opus 5.5.
// The devices' log: one line in the agreed format, a ring that keeps the
// newest 500, and the Watch's lines added on the iPhone once each.

@testable import AgentKeyringSealing
import Foundation
import Testing

struct DeviceLogTests {
    @Test func oneLineInTheAgreedFormat() {
        let line = DeviceLog.line(at: Date(timeIntervalSince1970: 0), device: "iphone", part: "answer", event: "sent",
                                  ["request": "2c3cc4a1", "reason": "the relay said no"])
        #expect(line == #"1970-01-01T00:00:00.000Z iphone answer sent request=2c3cc4a1 reason="the relay said no""#)
    }

    @Test func theRingKeepsTheNewestAndTheWatchsLinesOnce() throws {
        let file = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let log = DeviceLog(device: "iphone", file: file)
        for n in 0..<700 { log.note("test", "line", ["n": "\(n)"]) }
        let kept = log.lines(last: .max)
        #expect(kept.count <= DeviceLog.keep + DeviceLog.keep / 5)
        #expect(kept.last?.hasSuffix("n=699") == true)
        let watch = ["1970-01-01T00:00:00.000Z watch answer sent request=r1"]
        log.merge(watch); log.merge(watch)
        #expect(log.lines(last: .max).filter { $0 == watch[0] }.count == 1)
    }
}
