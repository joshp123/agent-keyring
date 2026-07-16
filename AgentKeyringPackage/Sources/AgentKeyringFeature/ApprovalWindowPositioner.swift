import AppKit
import CoreGraphics
import Foundation
import OSLog

private let approvalWindowLogger = Logger(
    subsystem: "com.agentkeyring.app",
    category: "ApprovalWindow"
)

@MainActor
public struct ApprovalWindowPresentation {
    public let window: NSWindow?
    public let closeWhenFinished: Bool
    public let miniaturizeWhenFinished: Bool

    public init(
        window: NSWindow?,
        closeWhenFinished: Bool,
        miniaturizeWhenFinished: Bool = false
    ) {
        self.window = window
        self.closeWhenFinished = closeWhenFinished
        self.miniaturizeWhenFinished = miniaturizeWhenFinished
    }
}

public typealias ApprovalWindowPresenter = @MainActor () async -> ApprovalWindowPresentation

struct ApprovalWindowPlacement {
    static func origin(
        windowSize: CGSize,
        systemPromptFrame: CGRect,
        visibleFrame: CGRect,
        gap: CGFloat = 24,
        margin: CGFloat = 20
    ) -> CGPoint {
        let safeFrame = visibleFrame.insetBy(dx: margin, dy: margin)
        let centredY = systemPromptFrame.midY - windowSize.height / 2
        let candidates = [
            CGPoint(
                x: systemPromptFrame.minX - gap - windowSize.width,
                y: centredY
            ),
            CGPoint(
                x: systemPromptFrame.maxX + gap,
                y: centredY
            ),
        ]

        if let fittingOrigin = candidates.first(where: {
            safeFrame.contains(CGRect(origin: $0, size: windowSize))
        }) {
            return fittingOrigin
        }

        return fallbackOrigin(windowSize: windowSize, visibleFrame: visibleFrame)
    }

    static func fallbackOrigin(windowSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.midY - windowSize.height / 2
        )
    }

    static func appKitFrame(
        quartzFrame: CGRect,
        displayBounds: CGRect,
        screenFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: screenFrame.minX + quartzFrame.minX - displayBounds.minX,
            y: screenFrame.minY
                + displayBounds.height
                - (quartzFrame.minY - displayBounds.minY)
                - quartzFrame.height,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
    }
}

@MainActor
enum ApprovalWindowPositioner {
    typealias SystemPromptWindowID = CGWindowID

    static func agentKeyringWindow() -> NSWindow? {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first(where: {
                $0.isVisible && $0.title == "Agent Keyring"
            })
    }

    static func centre(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        window.setFrameOrigin(
            ApprovalWindowPlacement.fallbackOrigin(
                windowSize: window.frame.size,
                visibleFrame: screen.visibleFrame
            )
        )
    }

    static func visibleSystemPromptWindowIDs() -> Set<SystemPromptWindowID> {
        Set(systemAuthenticationPrompts().map(\.id))
    }

    static func alignWhenSystemPromptAppears(
        _ window: NSWindow,
        excluding existingWindowIDs: Set<SystemPromptWindowID>
    ) async {
        for _ in 0..<30 {
            guard !Task.isCancelled else { return }
            if let prompt = newSystemAuthenticationPrompt(excluding: existingWindowIDs) {
                align(window, beside: prompt.frame, on: prompt.screen)
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { return }
                if let updatedPrompt = newSystemAuthenticationPrompt(
                    excluding: existingWindowIDs
                ) {
                    align(
                        window,
                        beside: updatedPrompt.frame,
                        on: updatedPrompt.screen
                    )
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        approvalWindowLogger.notice("Could not observe the system authentication panel")
    }

    private static func align(
        _ window: NSWindow,
        beside systemPromptFrame: CGRect,
        on screen: NSScreen
    ) {
        window.setFrameOrigin(
            ApprovalWindowPlacement.origin(
                windowSize: window.frame.size,
                systemPromptFrame: systemPromptFrame,
                visibleFrame: screen.visibleFrame
            )
        )
        approvalWindowLogger.info("Aligned the approval window with the system panel")
    }

    private static func newSystemAuthenticationPrompt(
        excluding existingWindowIDs: Set<SystemPromptWindowID>
    ) -> (id: SystemPromptWindowID, frame: CGRect, screen: NSScreen)? {
        let candidates = systemAuthenticationPrompts().filter {
            !existingWindowIDs.contains($0.id)
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    private static func systemAuthenticationPrompts() -> [(
        id: SystemPromptWindowID,
        frame: CGRect,
        screen: NSScreen
    )] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }

        var prompts = [(id: SystemPromptWindowID, frame: CGRect, screen: NSScreen)]()
        for entry in windowInfo {
            guard entry[kCGWindowOwnerName as String] as? String == "coreautha",
                let windowID = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                layer > 0,
                let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                let quartzFrame = CGRect(
                    dictionaryRepresentation: boundsDictionary as CFDictionary
                ),
                (180...500).contains(quartzFrame.width),
                (180...650).contains(quartzFrame.height),
                let match = screenContaining(quartzFrame: quartzFrame)
            else { continue }

            prompts.append(
                (
                    windowID,
                    ApprovalWindowPlacement.appKitFrame(
                        quartzFrame: quartzFrame,
                        displayBounds: match.displayBounds,
                        screenFrame: match.screen.frame
                    ),
                    match.screen
                ))
        }
        return prompts
    }

    private static func screenContaining(
        quartzFrame: CGRect
    ) -> (screen: NSScreen, displayBounds: CGRect)? {
        let midpoint = CGPoint(x: quartzFrame.midX, y: quartzFrame.midY)
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { continue }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            if displayBounds.contains(midpoint) {
                return (screen, displayBounds)
            }
        }
        return nil
    }
}
