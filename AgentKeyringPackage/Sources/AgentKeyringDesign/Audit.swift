// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// How the parts report a cut-off. Each `KeyringText` and `KeyringButton`
// reports where it was put; each text also reports, from SwiftUI's own
// text layout, whether it had to drop words to fit. Nothing reports unless
// a check installs a `KeyringAudit`, so the apps draw text exactly as SwiftUI
// does with no audit in place.

import Synchronization
import SwiftUI

/// Collects what the parts report while one screen is drawn.
public final class KeyringAudit: Sendable {
    public struct Element: Sendable, Hashable {
        public enum Kind: String, Sendable { case text, button }
        public let id: UUID
        public let kind: Kind
        /// The words, so a finding says which text it is.
        public let label: String
        /// The button whose label this text is, if any.
        public let owner: UUID?
    }

    private struct State {
        var frames: [UUID: (Element, CGRect)] = [:]
        /// Per text, its latest drawing: true if SwiftUI dropped words to fit.
        var truncated: [UUID: Bool] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    func place(_ element: Element, at frame: CGRect) {
        state.withLock { $0.frames[element.id] = (element, frame) }
    }

    func drew(_ id: UUID, truncated: Bool) {
        state.withLock { $0.truncated[id] = truncated }
    }

    /// What was wrong with the screen just drawn in `bounds`.
    public func findings(in bounds: CGRect) -> [KeyringFinding] {
        let snapshot = state.withLock { $0 }
        var found: [KeyringFinding] = []
        let placed = snapshot.frames.values.sorted { ($0.1.minY, $0.1.minX) < ($1.1.minY, $1.1.minX) }
        for (element, frame) in placed {
            if element.kind == .text {
                switch snapshot.truncated[element.id] {
                case true?: found.append(.truncated(element.label))
                case nil: found.append(.notDrawn(element.label))
                case false?: break
                }
            }
            if !bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame) {
                found.append(.outside(element.label, frame: frame))
            }
        }
        for (i, (a, frameA)) in placed.enumerated() {
            for (b, frameB) in placed[(i + 1)...] where a.owner != b.id && b.owner != a.id {
                let overlap = frameA.intersection(frameB)
                if !overlap.isNull, overlap.width > 0.5, overlap.height > 0.5 {
                    found.append(.overlapping(a.label, b.label))
                }
            }
        }
        return found
    }

    /// Every text drawn, top to bottom: the screen's words, for reading in one go.
    public var words: [String] {
        state.withLock { $0.frames.values.filter { $0.0.kind == .text }
            .sorted { ($0.1.minY, $0.1.minX) < ($1.1.minY, $1.1.minX) }.map(\.0.label) }
    }
}

public enum KeyringFinding: Sendable, Hashable, CustomStringConvertible {
    /// SwiftUI dropped words (an ellipsis or a cut line) to fit the text in its space.
    case truncated(String)
    /// Laid out but never drawn: hidden behind the window's edge or clipped away.
    case notDrawn(String)
    /// Placed partly or wholly outside the screen.
    case outside(String, frame: CGRect)
    /// Two texts or buttons on top of each other.
    case overlapping(String, String)

    public var description: String {
        switch self {
        case let .truncated(label): "cut off: “\(label)”"
        case let .notDrawn(label): "not drawn: “\(label)”"
        case let .outside(label, frame): "outside the screen at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height)): “\(label)”"
        case let .overlapping(a, b): "overlapping: “\(a)” and “\(b)”"
        }
    }
}

extension EnvironmentValues {
    /// Installed by the checks and the renderer; nil in the apps.
    @Entry public var keyringAudit: KeyringAudit?
    /// The button a text is the label of.
    @Entry var keyringAuditOwner: UUID?
    /// Set by the checks: scrolling pages lay out at full length, so every line is drawn and checked.
    @Entry public var keyringUnrollsScrolling = false
}

/// Draws the text as SwiftUI laid it out, and tells the audit whether words were dropped.
struct TruncationReporter: TextRenderer {
    let id: UUID
    let audit: KeyringAudit

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        audit.drew(id, truncated: layout.isTruncated)
        for line in layout { context.draw(line) }
    }
}

extension View {
    /// Reports this element's frame to the audit, if one is installed.
    func reportsPlacement(_ element: KeyringAudit.Element, to audit: KeyringAudit?) -> some View {
        modifier(PlacementReport(audit: audit, element: element))
    }
}

private struct PlacementReport: ViewModifier {
    let audit: KeyringAudit?
    let element: KeyringAudit.Element

    func body(content: Content) -> some View {
        if let audit {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { audit.place(element, at: $0) }
        } else {
            content
        }
    }
}
