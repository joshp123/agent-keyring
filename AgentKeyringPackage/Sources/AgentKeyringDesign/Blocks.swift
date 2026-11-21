// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Blocks a page puts in its body: text to copy, a QR code with its steps, and
// a group of device rows.

import SwiftUI
#if canImport(CoreImage.CIFilterBuiltins) && !os(watchOS)
import CoreImage.CIFilterBuiltins
#endif

#if !os(watchOS)
/// Text to copy, such as the note for an agent or a command, with its Copy button.
public struct KeyringCopyBlock: View {
    let label: String?
    let text: String
    let monospaced: Bool
    let more: [KeyringAction]
    @State private var copied = false

    /// `more`: other buttons under the text, such as Copy Prompt for Agent.
    public init(_ label: String? = nil, text: String, monospaced: Bool = false, more: [KeyringAction] = []) {
        self.label = label
        self.text = text
        self.monospaced = monospaced
        self.more = more
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s3) {
            HStack(alignment: .firstTextBaseline, spacing: KeyringSpace.s3) {
                if let label { KeyringText(label, as: .heading) }
                Spacer(minLength: 0)
                if more.isEmpty { copyButton }
            }
            // No text selection: selectable text is drawn by AppKit, out of the
            // audit's sight, and the Copy button already copies all of it.
            KeyringText(text, as: monospaced ? .code : .body)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !more.isEmpty {
                HStack(spacing: KeyringSpace.s2) {
                    ForEach(Array(more.enumerated()), id: \.offset) { KeyringButton($1) }
                    copyButton
                }
            }
        }
        .padding(KeyringSpace.s4)
        .background(KeyringPalette.fill, in: .rect(cornerRadius: KeyringRadius.card))
    }

    private var copyButton: some View {
        KeyringButton(.plain(copied ? PartsCopy.copied : PartsCopy.copy) {
            Pasteboard.copy(text)
            copied = true
        })
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}

/// A QR code beside the numbered steps that go with it (Add your iPhone).
public struct KeyringQRBlock: View {
    let url: String
    let steps: [String]

    public init(url: String, steps: [String]) {
        self.url = url
        self.steps = steps
    }

    public var body: some View {
        HStack(alignment: .top, spacing: KeyringSpace.s4) {
            KeyringQRCode(url)
                .frame(width: 96, height: 96)
                .padding(KeyringSpace.s2)
                .background(.white, in: .rect(cornerRadius: KeyringSpace.s2))
            VStack(alignment: .leading, spacing: KeyringSpace.s3) {
                ForEach(Array(steps.enumerated()), id: \.offset) { KeyringStepRow($0 + 1, $1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(KeyringSpace.s4)
        .background(KeyringPalette.fill, in: .rect(cornerRadius: KeyringRadius.card))
    }
}

/// A QR code for a link, drawn sharp at any size.
public struct KeyringQRCode: View {
    let url: String
    public init(_ url: String) { self.url = url }

    public var body: some View {
        if let image = Self.image(url) {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().accessibilityLabel(url)
        }
    }

    static func image(_ url: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
#endif

/// One device: its symbol, name, what it does, and what can be done with it.
public struct KeyringDeviceRow<Trailing: View>: View {
    /// Colours the symbol and the detail: green done, red refused, blue waiting, orange needs doing.
    public enum Tone: Sendable { case plain, approved, denied, waiting, needsDoing }
    /// Optional soft-tinted badge behind the symbol (used on Welcome feature points).
    public enum Badge: Sendable { case brand, approve, focus }
    let symbol: String
    let name: String
    let detail: String?
    let tone: Tone
    let badge: Badge?
    let nameFit: TextFit
    let trailing: Trailing

    /// `nameFit: .siteName` for a website, so a long one wraps at its dots.
    public init(symbol: String, name: String, detail: String? = nil, tone: Tone = .plain, badge: Badge? = nil,
                nameFit: TextFit = .wraps, @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.name = name
        self.nameFit = nameFit
        self.detail = detail
        self.tone = tone
        self.badge = badge
        self.trailing = trailing()
    }

    public var body: some View {
        TrailingOrBelow(belowFills: true) {
            HStack(alignment: badge == nil ? .firstTextBaseline : .top, spacing: KeyringSpace.s3) {
                if let badge {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(badgeForeground(badge))
                        .frame(width: 34, height: 34)
                        .background(badgeBackground(badge), in: .rect(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: symbol)
                        .font(KeyringTextRole.heading.font)
                        .foregroundStyle(tone == .plain ? KeyringPalette.ink : detailColour)
                        .frame(width: KeyringSpace.s6)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    KeyringText(name, as: .heading, fit: nameFit)
                    if let detail { KeyringText(detail, as: .meta, colour: detailColour) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            trailing.environment(\.keyringButtonsFill, true)
        }
        .padding(.vertical, KeyringSpace.s2)
    }

    private func badgeForeground(_ badge: Badge) -> Color {
        switch badge {
        case .brand: KeyringPalette.brand
        case .approve: KeyringPalette.approve
        case .focus: KeyringPalette.focus
        }
    }

    private func badgeBackground(_ badge: Badge) -> Color {
        switch badge {
        case .brand: KeyringPalette.brandTint
        case .approve: KeyringPalette.approveTint
        case .focus: KeyringPalette.focusTint
        }
    }

    private var detailColour: Color {
        switch tone {
        case .plain: KeyringPalette.ink2
        case .approved: KeyringPalette.approve
        case .denied: KeyringPalette.deny
        case .waiting: KeyringPalette.brand
        case .needsDoing: KeyringPalette.stalled
        }
    }
}

extension KeyringDeviceRow where Trailing == EmptyView {
    public init(symbol: String, name: String, detail: String? = nil, tone: Tone = .plain, badge: Badge? = nil, nameFit: TextFit = .wraps) {
        self.init(symbol: symbol, name: name, detail: detail, tone: tone, badge: badge, nameFit: nameFit) { EmptyView() }
    }
}

/// One line of a checklist (Notifications allowed, Time Sensitive): a green
/// tick when done, a neutral circle before it has been requested, or an orange
/// mark with what to do when it needs attention.
public struct KeyringCheckRow: View {
    public enum Status: Equatable, Sendable {
        case done
        case pending
        case needsAttention
    }

    let title: String
    let status: Status
    let toDo: String?

    public init(_ title: String, status: Status, toDo: String? = nil) {
        self.title = title
        self.status = status
        self.toDo = toDo
    }

    public init(_ title: String, isDone: Bool, toDo: String? = nil) {
        self.init(title, status: isDone ? .done : .needsAttention, toDo: toDo)
    }

    public var body: some View {
        let symbol: String = switch status {
        case .done: "checkmark.circle.fill"
        case .pending: "circle"
        case .needsAttention: "exclamationmark.circle.fill"
        }
        let tone: KeyringDeviceRow<EmptyView>.Tone = switch status {
        case .done: .approved
        case .pending: .plain
        case .needsAttention: .needsDoing
        }
        let spokenStatus: String = switch status {
        case .done: PartsCopy.checkDone
        case .pending: PartsCopy.checkPending
        case .needsAttention: PartsCopy.checkNeedsAttention
        }
        KeyringDeviceRow(symbol: symbol, name: title, detail: status == .done ? nil : toDo, tone: tone)
            .accessibilityElement(children: .combine)
            .accessibilityValue(spokenStatus)
    }
}

/// Rows in one rounded group with a hairline between them, as a page's body
/// shows them. The everyday tabs put the same rows in a system `List` instead.
public struct KeyringRowGroup<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    row.padding(.horizontal, KeyringSpace.s4).padding(.vertical, KeyringSpace.s1)
                }
            }
        }
        .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card))
        .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card).strokeBorder(KeyringPalette.line))
    }
}
