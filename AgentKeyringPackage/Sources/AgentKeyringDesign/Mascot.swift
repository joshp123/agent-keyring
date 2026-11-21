// Written by AI on 2026.11.21 by model claude opus 5.5, from the mascot
// states on board 5 of the Paper file "Agent Keyring" (shapes copied from
// the board's SVG, in its 100 by 100 grid).
//
// The app's keyhole with a face: a blue tile, a white keyhole, two eyes.

import SwiftUI

public struct KeyringMascot: View {
    public enum Mood: String, Sendable, CaseIterable {
        /// Setup and the app at rest: a smile.
        case calm
        /// Something new to look at: eyes up.
        case curious
        /// Waiting for an answer: eyes to the side.
        case waiting
        /// Approved: a happy squint.
        case approved
        /// Denied: startled, round eyes.
        case denied
        /// Offline: sleepy, closed eyes.
        case offline
    }

    let mood: Mood

    public init(_ mood: Mood = .calm) { self.mood = mood }

    public var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 100
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            let tile = Path(roundedRect: CGRect(x: 0, y: 0, width: 100 * s, height: 100 * s), cornerRadius: 22.5 * s, style: .continuous)
            context.fill(tile, with: .linearGradient(Gradient(colors: [Color(hex: 0x2F62F5), Color(hex: 0x1040D8)]), startPoint: .zero, endPoint: p(0, 100)))
            context.fill(Path(ellipseIn: CGRect(x: 28.5 * s, y: 17 * s, width: 43 * s, height: 43 * s)), with: .color(.white))
            var keyhole = Path()
            keyhole.move(to: p(40.2, 51.5))
            keyhole.addLine(to: p(59.8, 51.5))
            keyhole.addLine(to: p(67.2, 81.9))
            keyhole.addQuadCurve(to: p(64.1, 85.9), control: p(67.8, 85.9))
            keyhole.addLine(to: p(35.9, 85.9))
            keyhole.addQuadCurve(to: p(32.8, 81.9), control: p(32.2, 85.9))
            keyhole.closeSubpath()
            context.fill(keyhole, with: .color(.white))

            let ink = Color(hex: 0x0B1B4D)
            func eye(_ x: Double, _ y: Double, _ r: Double, glint: Double) {
                context.fill(Path(ellipseIn: CGRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s)), with: .color(ink))
                let gx = x + r * 0.31, gy = y - r * 0.33, gr = glint
                context.fill(Path(ellipseIn: CGRect(x: (gx - gr) * s, y: (gy - gr) * s, width: 2 * gr * s, height: 2 * gr * s)), with: .color(.white.opacity(0.9)))
            }
            func stroke(_ path: Path, _ width: Double) {
                context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: width * s, lineCap: .round))
            }
            func smile(from a: CGPoint, control c: CGPoint, to b: CGPoint, _ width: Double) {
                var path = Path(); path.move(to: a); path.addQuadCurve(to: b, control: c); stroke(path, width)
            }
            switch mood {
            case .calm:
                eye(45.8, 35.5, 4.9, glint: 1.8); eye(59.5, 35.5, 4.9, glint: 1.8)
                smile(from: p(45.5, 45.2), control: p(52.3, 50.4), to: p(59.1, 45.2), 3.2)
            case .curious:
                eye(45.5, 34.5, 4.9, glint: 1.8); eye(59.2, 34.5, 4.9, glint: 1.8)
                smile(from: p(45.5, 45), control: p(52, 49.8), to: p(58.5, 45), 3)
            case .waiting:
                eye(48.5, 35.5, 5.5, glint: 2); eye(62.2, 35.5, 5.5, glint: 2)
                smile(from: p(47, 46), control: p(52, 49.5), to: p(57, 46), 2.8)
            case .approved:
                smile(from: p(40.5, 36.5), control: p(45.3, 31.3), to: p(50.1, 36.5), 3.8)
                smile(from: p(54.2, 36.5), control: p(59, 31.3), to: p(63.8, 36.5), 3.8)
                smile(from: p(45, 45.5), control: p(52, 51), to: p(59, 45.5), 3.2)
            case .denied:
                for x in [46.3, 60.0] {
                    stroke(Path(ellipseIn: CGRect(x: (x - 5.2) * s, y: (37.5 - 5.2) * s, width: 10.4 * s, height: 10.4 * s)), 3.2)
                }
            case .offline:
                for x in [42.0, 55.8] {
                    var line = Path(); line.move(to: p(x, 38.5)); line.addLine(to: p(x + 8.5, 38.5)); stroke(line, 3.4)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
