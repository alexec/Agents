import AgentsKitCore
import AppKit
import SwiftUI

/// Sign in to an MCP server that asks for OAuth (#306). The host finds where to sign in and
/// waits for the browser on its own loopback; this opens the page in the person's browser
/// and waits with them. A sign-in with no registration asks for a client ID of their own.
struct MCPSignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let target: DaemonAPI.MCPSignInTarget
    var onSignedIn: () -> Void = {}

    private enum Step: Equatable {
        case starting
        case needsClient(issuer: String, callback: String)
        case waiting(flowID: UUID, page: URL)
        case failed(String)
    }

    @State private var step: Step = .starting
    @State private var clientID = ""
    @State private var clientSecret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to \(target.name)").appText(.title)
            switch step {
            case .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding where \(target.name) signs in…").appText(.fine).foregroundStyle(.secondary)
                }
            case .needsClient(let issuer, let callback):
                Text("\(issuer) doesn't let apps register themselves. Register an OAuth app there with the callback URL \(callback), then give its client ID here. The ID and secret are kept with your sign-ins in ~/.agents, not shown again.")
                    .appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder)
                SecureField("Client secret (if it has one)", text: $clientSecret).textFieldStyle(.roundedBorder)
            case .waiting(_, let page):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser. This closes by itself when you have.")
                        .appText(.fine).fixedSize(horizontal: false, vertical: true)
                }
                Button("Open the page again") { NSWorkspace.shared.open(page) } // store-ok: a web page in the browser, not a path
                    .buttonStyle(.paper).appText(.fine)
            case .failed(let why):
                Text(why).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { Task { await cancel() } }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
                switch step {
                case .needsClient:
                    Button("Sign in") { Task { await start() } }
                        .buttonStyle(.paperProminent)
                        .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                case .failed:
                    Button("Try again") { Task { await start() } }.buttonStyle(.paperProminent)
                default:
                    EmptyView()
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .paperSheet()
        .task { await start() }
        .onDisappear {
            // Closed while the browser was still out: the host stops listening for it.
            if case .waiting(let flowID, _) = step { Task { await model.mcpSignInCancel(flowID) } }
        }
    }

    private func start() async {
        let given: DaemonAPI.MCPSignInClient? = if case .needsClient = step {
            .init(id: clientID.trimmingCharacters(in: .whitespaces), secret: clientSecret.isEmpty ? nil : clientSecret)
        } else {
            nil
        }
        step = .starting
        let answer = await model.mcpSignIn(target, client: given)
        if let issuer = answer.needsClient {
            step = .needsClient(issuer: issuer, callback: answer.callback ?? "http://127.0.0.1/callback")
            return
        }
        guard let flowID = answer.flowID, let address = answer.authorizationURL, let page = URL(string: address) else {
            step = .failed(answer.error ?? "The sign-in couldn't start.")
            return
        }
        step = .waiting(flowID: flowID, page: page)
        NSWorkspace.shared.open(page) // store-ok: the sign-in page in the browser, not a path
        while case .waiting(let waiting, _) = step, waiting == flowID {
            switch await model.mcpSignInWait(flowID) {
            case .waiting:
                continue
            case .signedIn:
                onSignedIn()
                dismiss()
                return
            case .failed(let why):
                step = .failed(why)
            case .cancelled:
                return
            }
        }
    }

    private func cancel() async {
        if case .waiting(let flowID, _) = step {
            step = .starting
            await model.mcpSignInCancel(flowID)
        }
        dismiss()
    }
}
