import AgentsKitCore
import SwiftUI
import UIKit
import VisionKit

/// What a device with no way to its Mac shows: never paired, or forgotten (security
/// review, Phase 3). The one thing to do is scan the code the Mac shows in Settings ▸
/// Devices, on the same Wi-Fi, once; after that it reaches the Mac at home and away.
struct PairingView: View {
    @Environment(RemoteModel.self) private var model
    @State private var scanning = false

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "qrcode.viewfinder")
                // Decorative: a glyph above the words, not text, and hidden from VoiceOver.
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Pair with your Mac")
                .appText(.reading).fontWeight(.semibold)
                .multilineTextAlignment(.center)
            Text("On your Mac, open Agents ▸ Settings ▸ Devices and choose Pair a Device. "
                 + "Then scan the code it shows, with this \(device) on the same Wi-Fi.")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            outcome
            Button {
                model.forgetPairingOutcome()
                scanning = true
            } label: {
                Text(model.pairing == .idle ? "Scan the Code" : "Scan Again")
                    .appText(.reading).fontWeight(.semibold)
            }
            .buttonStyle(.paperProminent)
            .disabled(model.pairing == .pairing)
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $scanning) {
            ScanSheet { text in
                scanning = false
                Task { await model.pair(scanned: text) }
            }
        }
    }

    @ViewBuilder private var outcome: some View {
        switch model.pairing {
        case .idle:
            EmptyView()
        case .pairing:
            ProgressView("Pairing…")
                .appText(.fine)
        case .paired:
            Label("Paired", systemImage: "checkmark.circle")
                .appText(.fine)
        case .failed(let why):
            Text(why)
                .appText(.fine)
                .tinted(.failure)
                .multilineTextAlignment(.center)
        }
    }
}

/// The camera, looking for one QR code, and a way out.
private struct ScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    let found: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    Scanner(found: found)
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView("Can't use the camera",
                                           systemImage: "camera",
                                           description: Text("Allow Agents to use the camera in Settings, "
                                                             + "then try again."))
                }
            }
            .navigationTitle("Scan the Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// VisionKit's scanner, told about QR codes only, handing back the first one it reads.
private struct Scanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let found: (String) -> Void
        private var done = false

        init(found: @escaping (String) -> Void) {
            self.found = found
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                // Only an Agents code: another QR code in view is passed over, not reported.
                guard !done, let text = code.payloadStringValue, text.hasPrefix("agents-pair:") else { continue }
                done = true
                scanner.stopScanning()
                found(text)
                return
            }
        }
    }
}
