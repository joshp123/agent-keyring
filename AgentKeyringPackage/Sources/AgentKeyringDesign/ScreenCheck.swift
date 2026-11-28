// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Hosts a part or a page at a device's smallest size, draws it off screen,
// and returns what the audit found with the picture it drew. No window is
// ever shown: on the Mac it is a borderless window never ordered in, on
// iPhone a window with no scene, on the Watch SwiftUI's ImageRenderer.

import SwiftUI

/// Where a part or page is checked, and at what size.
public struct KeyringScreen: Sendable, Hashable {
    public let name: String
    public let size: CGSize
    /// Scrolling screens (iPhone, Watch) grow to their full length so every line is drawn and checked.
    public let scrolls: Bool
    public let colorScheme: ColorScheme
    public let dynamicTypeSize: DynamicTypeSize

    public init(_ name: String, size: CGSize, scrolls: Bool, colorScheme: ColorScheme = .light, dynamicTypeSize: DynamicTypeSize = .large) {
        self.name = name
        self.size = size
        self.scrolls = scrolls
        self.colorScheme = colorScheme
        self.dynamicTypeSize = dynamicTypeSize
    }

    /// The screens a part or page is checked on, on the platform the check runs on.
    public static func all(for kind: KeyringGalleryEntryKind) -> [KeyringScreen] {
        switch kind {
        case .macWindow:
            [.init("light", size: KeyringSize.macWindow, scrolls: false), .init("dark", size: KeyringSize.macWindow, scrolls: false, colorScheme: .dark)]
        case let .macPanel(width):
            [.init("light", size: CGSize(width: width, height: 0), scrolls: true), .init("dark", size: CGSize(width: width, height: 0), scrolls: true, colorScheme: .dark)]
        case .phone:
            [.init("default-text", size: KeyringSize.phone, scrolls: true),
             .init("largest-text", size: KeyringSize.phone, scrolls: true, dynamicTypeSize: .accessibility3),
             .init("dark", size: KeyringSize.phone, scrolls: true, colorScheme: .dark)]
        case .watch:
            [.init("41mm", size: KeyringSize.watch, scrolls: true, colorScheme: .dark)]
        }
    }
}

public struct KeyringCheckResult {
    public let findings: [KeyringFinding]
    /// The screen's words, top to bottom.
    public let words: [String]
    public let image: CGImage?
}

@MainActor
public enum ScreenCheck {
    public static func runLayoutCheck(_ view: some View, on screen: KeyringScreen) -> KeyringCheckResult {
        func prepared(_ audit: KeyringAudit?) -> some View {
            view
                .environment(\.keyringAudit, audit)
                .environment(\.keyringUnrollsScrolling, screen.scrolls)
                .environment(\.colorScheme, screen.colorScheme)
                .environment(\.dynamicTypeSize, screen.dynamicTypeSize)
        }
        var size = screen.size
        // Measured with no audit, so only the drawing that is checked reports.
        if screen.scrolls { size.height = max(size.height, height(prepared(nil), width: size.width).rounded(.up)) }
        var audit = KeyringAudit()
        var image: CGImage?
        // A scrolling screen is drawn as long as its content: a system List
        // fills whatever height it is given and lays out only the rows that
        // show, so it is drawn again, taller, until nothing lies below the end.
        for _ in 0..<8 {
            audit = KeyringAudit()
            image = draw(prepared(audit), size, screen.colorScheme)
            guard screen.scrolls, audit.lowestEdge > size.height + 0.5, size.height < 12_000 else { break }
            size.height = (audit.lowestEdge + screen.size.height).rounded(.up)
        }
        return KeyringCheckResult(findings: audit.findings(in: CGRect(origin: .zero, size: size)), words: audit.words, image: image)
    }

    #if os(macOS)
    private final class RetinaOffscreenWindow: NSWindow {
        override var backingScaleFactor: CGFloat { 2.0 }
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private static func applyRetinaScale(to view: NSView) {
        view.wantsLayer = true
        view.layer?.contentsScale = 2.0
        for subview in view.subviews { applyRetinaScale(to: subview) }
    }

    private static func applyRetinaScale(to layer: CALayer) {
        layer.contentsScale = 2.0
        for sublayer in layer.sublayers ?? [] { applyRetinaScale(to: sublayer) }
    }

    private static func height(_ root: some View, width: CGFloat) -> CGFloat {
        NSHostingView(rootView: root.frame(width: width)).fittingSize.height
    }

    private static func draw(_ root: some View, _ size: CGSize, _ scheme: ColorScheme) -> CGImage? {
        let host = NSHostingView(
            rootView: root
                .frame(width: size.width, height: size.height)
                .background(KeyringPalette.canvas)
                .environment(\.displayScale, 2.0)
                .environment(\.controlActiveState, .key)
        )
        host.frame = CGRect(origin: .zero, size: size)
        let window = RetinaOffscreenWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var image: CGImage?
        let pxW = max(1, Int((host.bounds.width * 2.0).rounded()))
        let pxH = max(1, Int((host.bounds.height * 2.0).rounded()))
        // Twice: the first pass settles layout that depends on measured sizes.
        for _ in 0..<2 {
            applyRetinaScale(to: host)
            if let layer = host.layer { applyRetinaScale(to: layer) }
            RunLoop.main.run(until: .now.addingTimeInterval(0.15))
            applyRetinaScale(to: host)
            if let layer = host.layer { applyRetinaScale(to: layer) }
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pxW,
                pixelsHigh: pxH,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { continue }
            bitmap.size = host.bounds.size
            if let appearance {
                appearance.performAsCurrentDrawingAppearance {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
            } else {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            image = bitmap.cgImage
        }
        window.contentView = nil
        return image
    }
    #elseif os(iOS)
    private static func height(_ root: some View, width: CGFloat) -> CGFloat {
        UIHostingController(rootView: root.frame(width: width)).sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    private static func draw(_ root: some View, _ size: CGSize, _ scheme: ColorScheme) -> CGImage? {
        let controller = UIHostingController(rootView: root.frame(width: size.width, height: size.height).background(KeyringPalette.surface))
        // No safe area: the checked layout must not depend on which simulator runs it.
        controller.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = window.bounds
        var image: CGImage?
        for _ in 0..<2 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            RunLoop.main.run(until: .now.addingTimeInterval(0.15))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
                window.layer.render(in: context.cgContext)
            }.cgImage
        }
        window.isHidden = true
        window.rootViewController = nil
        return image
    }
    #else
    /// ImageRenderer cannot measure without drawing, so the sizing pass draws too (with no audit).
    private static func height(_ root: some View, width: CGFloat) -> CGFloat {
        let renderer = ImageRenderer(content: root.frame(width: width).fixedSize(horizontal: false, vertical: true))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return renderer.cgImage.map { CGFloat($0.height) / renderer.scale } ?? 0
    }

    private static func draw(_ root: some View, _ size: CGSize, _ scheme: ColorScheme) -> CGImage? {
        let renderer = ImageRenderer(content: root.frame(width: size.width, height: size.height, alignment: .top).background(Color.black))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 2
        return renderer.cgImage
    }
    #endif
}
