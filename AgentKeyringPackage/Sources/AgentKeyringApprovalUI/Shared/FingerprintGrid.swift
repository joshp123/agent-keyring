// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The setup code two devices compare (RFC 0005): eight groups of four hex
// characters. Every screen and the command line lay it out the same way,
// two rows of four groups, so Josh compares row by row and group by group,
// the same position on both screens. All eight groups must match; there is
// deliberately no shorter or picture form to compare instead.

import SwiftUI

public struct FingerprintGrid: View {
    let groups: [String]
    let size: Font.TextStyle

    /// - Parameter code: "7F3A 91C2 0B4E D8A5 6C17 E902 44BB 13F0", with or
    ///   without spaces.
    public init(_ code: String, size: Font.TextStyle = .title2) {
        self.groups = FingerprintGrid.groups(code)
        self.size = size
    }

    public static func groups(_ code: String) -> [String] {
        let characters = Array(code.uppercased().filter { !$0.isWhitespace })
        return stride(from: 0, to: characters.count, by: 4).map {
            String(characters[$0 ..< min($0 + 4, characters.count)])
        }
    }

    public var body: some View {
        Grid(horizontalSpacing: 18, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: groups.count, by: 4)), id: \.self) { start in
                GridRow {
                    ForEach(start ..< min(start + 4, groups.count), id: \.self) { index in
                        Text(groups[index])
                            .font(.system(size, design: .monospaced).weight(.semibold))
                            .tracking(1.5)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(groups.map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", "))
    }
}
