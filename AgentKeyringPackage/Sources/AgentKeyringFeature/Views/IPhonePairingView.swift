import AgentKeyringApprovalCore
import AppKit
import CoreImage.CIFilterBuiltins
import Observation
import OSLog
import SwiftUI

private let pairingLogger = Logger(subsystem: "com.agentkeyring.app", category: "Pairing")

@MainActor
@Observable
final class IPhonePairingModel {
    private(set) var qrImage: NSImage?
    private(set) var candidate: PairingRequest?
    private(set) var expiresAt: Date?
    private(set) var message = "Preparing pairing code…"
    var confirmationCode = ""
    var canConfirm: Bool {
        candidate.map { confirmationCode == PairingRequest.confirmationCode(publicKey: $0.publicKey) } == true && !isSaving
    }
    private(set) var isSaving = false
    private var session: IPhonePairingSession?
    private var finished = false
    private let controller: CredentialAccessController

    init(controller: CredentialAccessController) { self.controller = controller }

    func run() async {
        do {
            let session = try IPhonePairingSession(database: PrivateApprovalCloudDatabase())
            self.session = session
            let code = session.code!
            expiresAt = code.expiresAt
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(code.qrPayload.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage,
                let image = CIContext().createCGImage(output, from: output.extent)
            else { throw PairingFailure.invalidCode }
            qrImage = NSImage(cgImage: image, size: NSSize(width: 280, height: 280))
            message = "Open Agent Keyring on your iPhone and tap Pair with Mac."
            while !finished {
                try Task.checkCancellation()
                if Date() >= code.expiresAt && !isSaving { throw PairingFailure.expired }
                if candidate == nil && !isSaving {
                    if let request = try await session.poll() {
                        try Task.checkCancellation()
                        candidate = request
                        qrImage = nil
                        message = "Type the six-digit code shown on your iPhone."
                    }
                }
                try await Task.sleep(for: .seconds(2))
            }
        } catch is CancellationError {
            // The sheet was closed. Cleanup below burns the QR and deletes its response.
        } catch {
            recordFailure(error)
            message = error as? PairingFailure == .expired
                ? "This pairing code expired. Close this window and choose Add iPhone again."
                : "Pairing failed. Close this window and choose Add iPhone again."
        }
        qrImage = nil
        candidate = nil
        do { try await session?.cancel() }
        catch {
            recordFailure(error)
            message = "Pairing ended, but its iCloud record could not be deleted."
        }
        session = nil
    }

    func confirm() async {
        guard let session, canConfirm else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await controller.confirmPairing(session, confirmationCode: confirmationCode)
            message = "iPhone added."
        } catch {
            recordFailure(error)
            message = "The iPhone was not added. Close this window and choose Add iPhone again."
        }
        candidate = nil
        finished = true
    }

    private func recordFailure(_ error: Error) {
        let error = error as NSError
        // CloudKit error descriptions can include records. Never log the QR or response.
        pairingLogger.error("Pairing failed domain=\(error.domain, privacy: .public) code=\(error.code)")
    }
}

struct IPhonePairingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: IPhonePairingModel

    init(controller: CredentialAccessController) {
        _model = State(initialValue: IPhonePairingModel(controller: controller))
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 16) {
            Text("Add iPhone").font(.title2)
            if let image = model.qrImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280, height: 280)
                    .padding(16)
                    .background(.white)
                    .accessibilityLabel("One-time pairing QR code")
            }
            if let candidate = model.candidate {
                Text(candidate.deviceName).font(.headline)
                TextField("Six-digit code from your iPhone", text: $model.confirmationCode)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Six-digit code from your iPhone")
                Button("Add iPhone with Touch ID") { Task { await model.confirm() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canConfirm)
            }
            Text(model.message)
            if let expiry = model.expiresAt, model.qrImage != nil || model.candidate != nil {
                Text("Expires \(expiry, format: .dateTime.hour().minute().second())")
                    .foregroundStyle(.secondary)
            }
            Button(model.qrImage != nil || model.candidate != nil ? "Cancel" : "Done") { dismiss() }
                .disabled(model.isSaving)
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled(model.isSaving)
        .task { await model.run() }
    }
}

struct IPhoneDevicesView: View {
    let controller: CredentialAccessController
    @State private var showingPairing = false
    @State private var removalError: String?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("iPhone approvals", systemImage: "iphone")
                Button("Add iPhone") { showingPairing = true }
                    .disabled(controller.needsConfirmation || controller.isSavingRules)
            }
            ForEach(controller.pairedApprovalDevices, id: \.publicKey) { device in
                HStack {
                    Text(device.name).foregroundStyle(.secondary)
                    Button("Remove iPhone", role: .destructive) {
                        Task {
                            removalError = nil
                            do { try await controller.removePairedApprovalDevice(publicKey: device.publicKey) }
                            catch { removalError = "The iPhone could not be removed." }
                        }
                    }
                    .disabled(controller.isSavingRules)
                }
            }
            if let removalError { Text(removalError).foregroundStyle(.red) }
        }
        .sheet(isPresented: $showingPairing) { IPhonePairingView(controller: controller) }
    }
}
