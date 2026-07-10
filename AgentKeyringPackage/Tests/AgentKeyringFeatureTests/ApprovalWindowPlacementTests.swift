import Foundation
import Testing
@testable import AgentKeyringFeature

@Suite("Approval window placement")
struct ApprovalWindowPlacementTests {
    @Test("A wide display places the app to the left of the system prompt")
    func sideBySidePlacement() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        let windowSize = CGSize(width: 560, height: 430)
        let promptFrame = CGRect(x: 626, y: 336, width: 260, height: 310)

        let origin = ApprovalWindowPlacement.origin(
            windowSize: windowSize,
            systemPromptFrame: promptFrame,
            visibleFrame: visibleFrame
        )

        let window = CGRect(origin: origin, size: windowSize)
        #expect(window.maxX == promptFrame.minX - 24)
        #expect(window.midY == promptFrame.midY)
        #expect(visibleFrame.contains(window))
    }

    @Test("A narrow display keeps the app fully visible")
    func narrowDisplayFallback() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let windowSize = CGSize(width: 560, height: 430)
        let promptFrame = CGRect(x: 320, y: 195, width: 260, height: 310)

        let origin = ApprovalWindowPlacement.origin(
            windowSize: windowSize,
            systemPromptFrame: promptFrame,
            visibleFrame: visibleFrame
        )

        #expect(
            visibleFrame.insetBy(dx: 20, dy: 20)
                .contains(CGRect(origin: origin, size: windowSize))
        )
    }

    @Test("Quartz top-left coordinates convert to AppKit bottom-left coordinates")
    func coordinateConversion() {
        let converted = ApprovalWindowPlacement.appKitFrame(
            quartzFrame: CGRect(x: 3_710, y: 479, width: 260, height: 278),
            displayBounds: CGRect(x: 0, y: 0, width: 7_680, height: 2_160),
            screenFrame: CGRect(x: 0, y: 0, width: 7_680, height: 2_160)
        )

        #expect(converted == CGRect(x: 3_710, y: 1_403, width: 260, height: 278))
    }
}
