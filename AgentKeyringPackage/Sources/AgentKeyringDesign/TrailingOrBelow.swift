// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Words with a control at their end (a row's button, the reply box's
// microphone). The control keeps its natural width, so its label never
// wraps; when that would leave the words less than half the row, the
// control moves under them instead, as Apple's own lists do at large text.

import SwiftUI

struct TrailingOrBelow: Layout {
    var spacing: CGFloat = KeyringSpace.s3
    /// Where the control sits when it moves under the words.
    var belowAlignment: HorizontalAlignment = .leading
    /// Beside the words: at their bottom (the microphone) rather than their middle (a row's button).
    var besideAtBottom = false
    /// Under the words, the control takes the row's whole width (a row's button), else its own (the microphone).
    var belowFills = false

    /// The control's size under the words: never wider than the row.
    private func below(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        return subview.sizeThatFits(ProposedViewSize(width: belowFills ? width : min(ideal.width, width), height: nil))
    }

    private func beside(_ width: CGFloat, _ control: CGSize) -> Bool {
        width - control.width - spacing >= width / 2
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else {
            return subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        }
        let control = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width ?? (subviews[0].sizeThatFits(.unspecified).width + spacing + control.width)
        if beside(width, control) {
            let words = subviews[0].sizeThatFits(ProposedViewSize(width: width - control.width - spacing, height: nil))
            return CGSize(width: width, height: max(words.height, control.height))
        }
        let words = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: words.height + spacing + below(subviews[1], width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            return
        }
        let control = subviews[1].sizeThatFits(.unspecified)
        if beside(bounds.width, control) {
            let wordsWidth = bounds.width - control.width - spacing
            let words = subviews[0].sizeThatFits(ProposedViewSize(width: wordsWidth, height: nil))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY - words.height / 2),
                              proposal: ProposedViewSize(width: wordsWidth, height: words.height))
            subviews[1].place(at: CGPoint(x: bounds.maxX - control.width, y: besideAtBottom ? bounds.maxY - control.height : bounds.midY - control.height / 2),
                              proposal: ProposedViewSize(control))
        } else {
            let words = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: words.height))
            let size = below(subviews[1], width: bounds.width)
            let x = belowAlignment == .trailing ? bounds.maxX - size.width : bounds.minX
            subviews[1].place(at: CGPoint(x: x, y: bounds.minY + words.height + spacing), proposal: ProposedViewSize(size))
        }
    }
}
