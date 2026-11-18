// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// First run on the iPhone (Paper, "First run and the app", the last row):
// scan the code on the Mac, turn on notifications, then offer the Watch.

#if os(iOS)
import SwiftUI
import VisionKit

struct PhoneFirstRunView: View {
    let model: PhoneModel

    var body: some View {
        Group {
            switch model.snapshot.setup {
            case .scanCode, .ready: scan
            case .turnOnNotifications: notifications
            case .offerWatch: watch
            }
        }
        .background(Phone.surface)
        .alert(model.failure ?? "", isPresented: failureShown) {
            Button(PhoneCopy.ok) { model.dismissFailure() }
        }
    }

    private var scan: some View {
        VStack(spacing: 18) {
            KeyholeIcon(size: 72)
            VStack(spacing: 6) {
                Text(PhoneCopy.appName)
                    .font(.largeTitle.bold()).tracking(-0.75).foregroundStyle(Phone.ink)
                Text(PhoneCopy.firstRunLead)
                    .font(.body).foregroundStyle(Phone.ink2)
            }
            Color.clear.frame(height: 6)
            CodeScanner { code in Task { await model.join(scannedCode: code) } }
            Text(PhoneCopy.pointCamera)
                .font(.body).foregroundStyle(Phone.ink2)
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .padding(.top, 40)
    }

    private var notifications: some View {
        Step(title: PhoneCopy.canApprove, lead: PhoneCopy.turnOnNotificationsLead) {
            Circle().fill(Phone.approve).frame(width: 64, height: 64)
                .overlay(Image(systemName: "checkmark").font(.system(size: 28, weight: .bold)).foregroundStyle(Phone.onAnswer))
        } actions: {
            Button(PhoneCopy.turnOnNotifications) { Task { await model.turnOnNotifications() } }
                .buttonStyle(PillButtonStyle(fill: Phone.ink, text: Phone.surface))
        }
        .padding(.bottom, 12)
    }

    private var watch: some View {
        Step(title: PhoneCopy.watchQuestion, lead: PhoneCopy.watchLead) {
            WatchOutline().stroke(Phone.ink, style: StrokeStyle(lineWidth: 4.2, lineCap: .round, lineJoin: .round))
                .frame(width: 72, height: 72)
        } actions: {
            VStack(spacing: 6) {
                Button { Task { await model.allowWatch() } } label: {
                    Label(PhoneCopy.allowWithFaceID, systemImage: "faceid")
                }
                .buttonStyle(PillButtonStyle(fill: Phone.ink, text: Phone.surface))
                Button(PhoneCopy.notNow) { model.skipWatch() }
                    .font(.body.weight(.semibold)).foregroundStyle(Phone.ink)
                    .frame(height: 44)
            }
        }
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { model.failure != nil }, set: { if !$0 { model.dismissFailure() } })
    }
}

/// A symbol, a title and a sentence in the middle; the answers at the bottom.
private struct Step<Symbol: View, Actions: View>: View {
    let title: String
    let lead: String
    @ViewBuilder let symbol: Symbol
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                symbol
                Text(title).font(.title.bold()).tracking(-0.56).foregroundStyle(Phone.ink)
                Text(lead).font(.body).foregroundStyle(Phone.ink2)
            }
            .multilineTextAlignment(.center)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 40)
            actions
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 44)
    }
}

/// Paper's Watch, drawn in a 24-point box: case, straps and crown.
private struct WatchOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        var path = Path(roundedRect: CGRect(x: 6.6 * s, y: 6 * s, width: 10.8 * s, height: 12 * s), cornerRadius: 3.2 * s, style: .continuous)
        path.move(to: p(9, 6)); path.addLine(to: p(9.7, 2.6)); path.addLine(to: p(14.3, 2.6)); path.addLine(to: p(15, 6))
        path.move(to: p(9, 18)); path.addLine(to: p(9.7, 21.4)); path.addLine(to: p(14.3, 21.4)); path.addLine(to: p(15, 18))
        path.move(to: p(18.9, 10.4)); path.addLine(to: p(18.9, 13))
        return path
    }
}

/// The camera, 300 pt square, with the four corner marks. Calls back once per code.
private struct CodeScanner: View {
    let scanned: (String) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color(rgb: 0x16181D))
            if DataScannerViewController.isSupported {
                Scanner(scanned: scanned).clipShape(.rect(cornerRadius: 30, style: .continuous))
            }
            Corners().stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .butt)).padding(16)
        }
        .frame(width: 300, height: 300)
        .accessibilityLabel(PhoneCopy.pointCamera)
    }

    private struct Corners: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let length: CGFloat = 44, radius: CGFloat = 12
            for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                     (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
                path.move(to: CGPoint(x: corner.x, y: corner.y + dy * length))
                path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * radius))
                path.addQuadCurve(to: CGPoint(x: corner.x + dx * radius, y: corner.y), control: corner)
                path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
            }
            return path
        }
    }

    private struct Scanner: UIViewControllerRepresentable {
        let scanned: (String) -> Void

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                       qualityLevel: .balanced, isHighlightingEnabled: false)
            controller.delegate = context.coordinator
            try? controller.startScanning()
            return controller
        }

        func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned) }

        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let scanned: (String) -> Void
            var seen = Set<String>()
            init(scanned: @escaping (String) -> Void) { self.scanned = scanned }

            func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
                for case let .barcode(code) in items {
                    guard let text = code.payloadStringValue, seen.insert(text).inserted else { continue }
                    scanned(text)
                }
            }
        }
    }
}
#endif
