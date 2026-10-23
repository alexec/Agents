import AgentsKitCore
import SwiftUI
import UIKit
import VisionKit

/// What a device with no way to its Mac shows: never paired, or forgotten (security
/// review, Phase 3). Sign-in comes first (#2097): the control plane's address, then its
/// providers. **Use a Code Instead…** scans or pastes the code the control plane shows (Agents
/// Host's Pair a Window or Phone…, or the window's Pair a Device), as a local owner with no
/// sign-in provider does; an address with no provider on goes there by itself.
struct PairingView: View {
    @Environment(RemoteModel.self) private var model
    @State private var scanning = false
    /// The code's way, not the sign-in's.
    @State private var usingCode = false
    /// Why the code's way came by itself: the address had no provider on.
    @State private var noneOn = false

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    var body: some View {
        VStack(spacing: 12) {
            // The mark of a team (#1007), above the words; it hides itself from VoiceOver.
            Huddle(promptFocused: false, pointer: nil, height: 64)
                .padding(.bottom, 4)
            Text("Connect to your agents")
                .appText(.reading).fontWeight(.semibold)
                .multilineTextAlignment(.center)
            if usingCode { code } else { signIn }
            outcome
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

    /// With no code (#995): sign in as a person the control plane knows.
    @ViewBuilder private var signIn: some View {
        Text("Type your control plane’s address. Sign in with an account added to your person there.")
            .appText(.fine)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        SignInToPair(pair: { url, signIn, waiting in
            try await model.pairBySigningIn(at: url, with: signIn, waiting: waiting)
        }, sentence: { error in
            let words = SignInToPair.words(error)
            if words == SignInWords.noneOn {
                Task { @MainActor in
                    noneOn = true
                    usingCode = true
                }
            }
            return words ?? PairingAttempt.sentence(for: error, device: "this \(device)")
        }, done: {})
        .padding(.top, 8)
        Button(SignInWords.useCode) {
            noneOn = false
            usingCode = true
        }
        .disabled(model.pairing == .pairing)
        .padding(.top, 4)
    }

    @ViewBuilder private var code: some View {
        Text(noneOn ? SignInWords.noneOn
             : "On your Mac, choose Pair a Window or Phone… in Agents Host, or Pair a Device in "
               + "Agents ▸ Settings. Then scan the code it shows, or copy it and paste it here.")
            .appText(.fine)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
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
        // A code sent as text, as App Review is given one (058, T092).
        PasteButton(payloadType: String.self) { strings in
            guard let text = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            model.forgetPairingOutcome()
            Task { await model.pair(scanned: text) }
        }
        .disabled(model.pairing == .pairing)
        Button(SignInWords.useSignIn) { usingCode = false }
            .disabled(model.pairing == .pairing)
            .padding(.top, 4)
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
                // Only a control plane's code: another QR code in view, or a first-build Mac's
                // agents-pair code, is passed over, not reported.
                guard !done, let text = code.payloadStringValue, text.hasPrefix("agents-control:") else { continue }
                done = true
                scanner.stopScanning()
                found(text)
                return
            }
        }
    }
}
