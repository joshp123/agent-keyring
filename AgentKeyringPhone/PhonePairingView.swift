import AVFoundation
import SwiftUI
import VisionKit

struct PhonePairingView: View {
    let model: PhoneApprovalModel
    @Environment(\.dismiss) private var dismiss
    @State private var cameraReady = false
    @State private var message = "Allow camera access to scan the pairing code on your Mac."
    @State private var scanned = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if cameraReady && !scanned {
                    PairingQRScanner { payload in
                        scanned = true
                        cameraReady = false
                        Task { await model.pair(qrPayload: payload) }
                    } onFailure: {
                        cameraReady = false
                        message = "The camera is unavailable. Close this window and try again."
                    }
                } else if scanned {
                    Text(model.pairingStatus ?? "Sending pairing request…")
                    if let code = model.pairingConfirmationCode {
                        Text(code)
                            .font(.system(.largeTitle, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Type this code on your Mac, then confirm there with Touch ID.")
                    }
                } else {
                    Text(message)
                }
            }
            .padding()
            .navigationTitle("Pair with Mac")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                guard DataScannerViewController.isSupported else {
                    message = "QR scanning is not supported on this iPhone."
                    return
                }
                let permitted = await AVCaptureDevice.requestAccess(for: .video)
                guard !Task.isCancelled else { return }
                cameraReady = permitted && DataScannerViewController.isAvailable
                if !permitted { message = "Enable Camera for Agent Keyring in iPhone Settings, then try again." }
                else if !cameraReady { message = "The camera is unavailable. Close this window and try again." }
            }
        }
    }
}

private struct PairingQRScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onFailure: onFailure) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() }
        catch { onFailure() }
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private let onFailure: () -> Void
        private var scanned = false

        init(onScan: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
            self.onScan = onScan
            self.onFailure = onFailure
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !scanned else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    scanned = true
                    scanner.stopScanning()
                    onScan(payload)
                    return
                }
            }
        }

        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            scanner.stopScanning()
            onFailure()
        }
    }
}
