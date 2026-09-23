import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins
import VisionKit

/// Shown on the old device: a one-time QR code / text code that moves this installation elsewhere.
struct MigrationExportView: View {
    @EnvironmentObject private var store: CallbackStore
    @Environment(\.dismiss) private var dismiss
    @State private var code: MigrationCode?
    @State private var qrImage: UIImage?
    @State private var expiresAt = Date()
    @State private var status = MigrationStatus.pending
    @State private var working = false
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                if status == .completed {
                    ContentUnavailableView {
                        Label("Migration complete", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text("Your Callbacks, templates, history and Push URL now belong to the new device. This device has been disconnected.")
                    }
                } else if status == .expired {
                    ContentUnavailableView {
                        Label("Code expired", systemImage: "clock.badge.exclamationmark")
                    } description: {
                        Text("Create a new code to continue.")
                    } actions: {
                        Button("Create new code") { Task { await generate() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if let code {
                    Section {
                        if let qrImage {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 240)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .accessibilityLabel("Migration QR code")
                        }
                    } footer: {
                        Text("On the new device, open NotifyGo → Settings → Migrate from Another Device, then scan this code.")
                    }

                    Section {
                        Button {
                            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: code.text]], options: [.expirationDate: expiresAt])
                            copied = true
                        } label: {
                            Text(code.text)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .sensoryFeedback(.success, trigger: copied)
                        .accessibilityLabel(copied ? "Migration code copied" : "Copy migration code")
                    } header: {
                        Text("Migration code")
                    } footer: {
                        Text("Expires \(Text(expiresAt, style: .relative)). Anyone with this code can take over your Callbacks, so only use it on your own device.")
                    }
                } else if let error {
                    Section { Text(error).foregroundStyle(.red) }
                    Section { Button("Retry") { Task { await generate() } } }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Move to a New Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: status == .completed ? .confirmationAction : .cancellationAction) {
                    Button(status == .completed ? "Done" : "Cancel") { dismiss() }
                }
            }
            .task { await generate() }
            .task(id: code?.lookup) { await poll() }
            .onDisappear {
                guard status == .pending, code != nil else { return }
                Task { try? await store.cancelMigration() }
            }
            .onChange(of: copied) { _, value in
                guard value else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
        }
    }

    private func generate() async {
        guard !working else { return }
        working = true
        defer { working = false }
        error = nil
        do {
            let result = try await store.createMigration()
            code = result.code
            expiresAt = result.expiresAt
            qrImage = Self.qrCode(result.code.text)
            status = .pending
        } catch {
            code = nil
            self.error = error.localizedDescription
        }
    }

    // The old device learns the migration finished when its own credential stops being accepted.
    private func poll() async {
        guard code != nil else { return }
        while !Task.isCancelled, status == .pending {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let value = try? await store.migrationStatus() else { continue }
            if value != .pending {
                withAnimation { status = value }
                if value == .expired { code = nil }
            }
        }
    }

    private static func qrCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Shown on the new device: accepts a scanned or pasted migration code.
struct MigrationImportView: View {
    @EnvironmentObject private var store: CallbackStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var scanning = false
    @State private var confirming = false
    @State private var working = false
    @State private var completed = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if completed {
                    ContentUnavailableView {
                        Label("Migration complete", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text("Your Callbacks, templates, history and Push URL are now on this device. Existing URLs keep working.")
                    }
                } else {
                    if !store.callbacks.isEmpty {
                        Section {
                            Label("This device already has Callbacks. Delete them before migrating, or migrate to a device without Callbacks.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    Section {
                        TextField("NGM1-…", text: $code, axis: .vertical)
                            .font(.footnote.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        PasteButton(payloadType: String.self) { values in
                            if let value = values.first { code = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                        if DataScannerViewController.isSupported {
                            Button("Scan QR Code", systemImage: "qrcode.viewfinder") { scanning = true }
                        }
                    } header: {
                        Text("Migration code")
                    } footer: {
                        Text("On your old device, open NotifyGo → Settings → Move to a New Device.")
                    }
                    Section {
                        Button {
                            error = nil
                            if MigrationCode(code) == nil { error = CallbackError.migrationCode.localizedDescription }
                            else { confirming = true }
                        } label: {
                            if working { ProgressView().frame(maxWidth: .infinity) }
                            else { Text("Migrate to This Device").frame(maxWidth: .infinity) }
                        }
                        .disabled(working || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                }
            }
            .navigationTitle("Migrate from Another Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: completed ? .confirmationAction : .cancellationAction) {
                    Button(completed ? "Done" : "Cancel") { dismiss() }
                }
            }
            .confirmationDialog("Migrate to this device?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Migrate") { Task { await redeem() } }
            } message: {
                Text("Callbacks, templates, history and the Push URL move here, and the old device is disconnected immediately. URLs saved in App Store Connect and other services keep working.")
            }
            .sheet(isPresented: $scanning) {
                MigrationScannerSheet { value in
                    code = value
                    scanning = false
                }
            }
        }
    }

    private func redeem() async {
        working = true
        defer { working = false }
        do {
            try await store.redeemMigration(code)
            withAnimation { completed = true }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MigrationScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isAvailable {
                    MigrationScanner(onScan: onScan).ignoresSafeArea()
                } else {
                    ContentUnavailableView("Camera unavailable", systemImage: "camera.fill",
                                           description: Text("Allow camera access for NotifyGo in Settings, or paste the code instead."))
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

private struct MigrationScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var delivered = false

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard !delivered, case .barcode(let barcode) = item, let value = barcode.payloadStringValue,
                      MigrationCode(value) != nil else { continue }
                delivered = true
                onScan(value)
            }
        }
    }
}
