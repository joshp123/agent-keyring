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
    public static func all(for kind: KeyringGalleryEntry.Kind) -> [KeyringScreen] {
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
    public static func run(_ view: some View, on screen: KeyringScreen) -> KeyringCheckResult {
        func prepared(_ audit: KeyringAudit?) -> some View {
            view
                .environment(\.keyringAudit, audit)
                .environment(\.keyringUnrollsScrolling, screen.scrolls)
                .environment(\.colorScheme, screen.colorScheme)
                .environment(\.dynamicTypeSize, screen.dynamicTypeSize)
        }
        let audit = KeyringAudit()
        #if os(watchOS)
        // ImageRenderer sizes a scrolling screen itself: as tall as its words, at least the Watch's height.
        let (image, size) = draw(prepared(audit), screen.size, scrolls: screen.scrolls)
        #else
        var size = screen.size
        // Measured with no audit, so only the drawing that is checked reports.
        if screen.scrolls { size.height = max(size.height, height(prepared(nil), width: size.width).rounded(.up)) }
        let image = draw(prepared(audit), size, screen.colorScheme)
        #endif
        return KeyringCheckResult(findings: audit.findings(in: CGRect(origin: .zero, size: size)), words: audit.words, image: image)
    }

    #if os(macOS)
    private static func height(_ root: some View, width: CGFloat) -> CGFloat {
        NSHostingView(rootView: root.frame(width: width)).fittingSize.height
    }

    private static func draw(_ root: some View, _ size: CGSize, _ scheme: ColorScheme) -> CGImage? {
        let host = NSHostingView(rootView: root.frame(width: size.width, height: size.height).background(KeyringPalette.surface))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var image: CGImage?
        // Twice: the first pass settles layout that depends on measured sizes.
        for _ in 0..<2 {
            RunLoop.main.run(until: .now.addingTimeInterval(0.15))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: bitmap)
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
            format.scale = 2
            image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
                window.layer.render(in: context.cgContext)
            }.cgImage
        }
        window.isHidden = true
        window.rootViewController = nil
        return image
    }
    #else
    private static func draw(_ root: some View, _ size: CGSize, scrolls: Bool) -> (CGImage?, CGSize) {
        let content = root.frame(width: size.width).frame(minHeight: size.height, alignment: .top).background(Color.black)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: size.width, height: scrolls ? nil : size.height)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return (nil, size) }
        return (image, CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }
    #endif
}
