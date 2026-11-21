// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Numbered steps: one two-column row, the number in a fixed column and the
// words beside it, used on every device.

import SwiftUI

/// One numbered step. Anything under the words (a picture, a note) goes in `extra`.
public struct KeyringStepRow<Extra: View>: View {
    let number: Int
    let words: String
    let extra: Extra

    public init(_ number: Int, _ words: String, @ViewBuilder extra: () -> Extra) {
        self.number = number
        self.words = words
        self.extra = extra()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: KeyringSpace.s3) {
            KeyringText("\(number)", as: .caption, colour: KeyringPalette.brand)
                .monospacedDigit()
                .frame(minWidth: Self.column, minHeight: Self.column)
                .background(KeyringPalette.brandTint, in: .circle)
            VStack(alignment: .leading, spacing: KeyringSpace.s2) {
                KeyringText(words, as: .body)
                extra
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static var column: CGFloat {
        #if os(watchOS)
        18
        #else
        22
        #endif
    }
}

extension KeyringStepRow where Extra == EmptyView {
    public init(_ number: Int, _ words: String) { self.init(number, words) { EmptyView() } }
}

/// A list of numbered steps on a grey card.
public struct KeyringSteps: View {
    let steps: [String]

    public init(_ steps: [String]) { self.steps = steps }

    public var body: some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s3) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                KeyringStepRow(index + 1, step)
            }
        }
        .padding(KeyringSpace.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KeyringPalette.fill, in: .rect(cornerRadius: KeyringRadius.card))
    }
}
