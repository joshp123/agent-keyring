// Written by AI on 2026.11.16 by model Claude Opus 5.5.
//
// Where a request panel appears: next to the window Josh is working in, so
// he sees it where he is already looking on a laptop or a 57-inch screen,
// without it covering his work or taking his keystrokes.

#if os(macOS)
import AppKit

public enum ApprovalPanelPlacement {
    static let gap: CGFloat = 12
    /// Further than this from the pointer, a corner is out of Josh's sight.
    static let farFromPointer: CGFloat = 1200

    /// The panel's frame, in AppKit screen coordinates (origin bottom left).
    ///
    /// 1. Beside the focused window, top-aligned with it, on the side with
    ///    room: the right first, then the left.
    /// 2. Otherwise, as on a laptop with a full-size window, inside the
    ///    window's top-right corner; or, if that corner is far from the
    ///    pointer, inside its top edge, centred under the pointer.
    /// 3. With no focused window, at the top of the screen with the pointer,
    ///    centred under it.
    public static func frame(panel size: CGSize, focusedWindow: CGRect?, pointer: CGPoint,
        visibleFrames: [CGRect]) -> CGRect {
        let screen = visibleFrames.first { $0.contains(focusedWindow.map { CGPoint(x: $0.midX, y: $0.midY) } ?? pointer) }
            ?? visibleFrames.first { $0.contains(pointer) } ?? visibleFrames.first ?? .zero
        guard let window = focusedWindow?.intersection(screen), !window.isNull, window.width > 0 else {
            return clamp(CGRect(x: pointer.x - size.width / 2, y: screen.maxY - gap - size.height,
                width: size.width, height: size.height), to: screen)
        }
        let top = min(window.maxY, screen.maxY) - size.height
        if screen.maxX - window.maxX >= size.width + 2 * gap {
            return clamp(CGRect(x: window.maxX + gap, y: top, width: size.width, height: size.height), to: screen)
        }
        if window.minX - screen.minX >= size.width + 2 * gap {
            return clamp(CGRect(x: window.minX - gap - size.width, y: top, width: size.width, height: size.height),
                to: screen)
        }
        // Its top-right corner is close enough on a laptop; on a very wide
        // window that corner can be a metre away, so follow the pointer.
        let corner = window.maxX - gap - size.width
        let x = abs(corner + size.width / 2 - pointer.x) <= farFromPointer ? corner
            : min(max(pointer.x - size.width / 2, window.minX + gap), corner)
        return clamp(CGRect(x: x, y: window.maxY - gap - size.height, width: size.width, height: size.height),
            to: screen)
    }

    static func clamp(_ rect: CGRect, to screen: CGRect) -> CGRect {
        var r = rect
        r.origin.x = min(max(r.minX, screen.minX + gap), screen.maxX - gap - r.width)
        r.origin.y = min(max(r.minY, screen.minY + gap), screen.maxY - gap - r.height)
        return r
    }

    /// The frontmost app's frontmost ordinary window, in AppKit coordinates.
    /// Window bounds need no Screen Recording permission; titles would.
    @MainActor static func focusedWindow() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
            let mainHeight = NSScreen.screens.first?.frame.height
        else { return nil }
        for info in list {
            guard info[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                info[kCGWindowLayer as String] as? Int == 0,
                let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds),
                rect.width > 200, rect.height > 150
            else { continue }
            // Quartz measures from the top of the main screen; AppKit from its bottom.
            return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }
}
#endif
