import AgentsKitCore
import AppKit
import SwiftUI

/// Sign In… on a server's Claude or Codex (#4698), as the web page's RuntimeSignInDialog (#3349)
/// and the Remote's RuntimeSignInSheet (#4035): the machine has no browser, so the runtime's own
/// sign-in runs there and gives a link to open here. Claude's page then gives a code to paste
/// back; Codex gives a code to type on its page. An API key is the other way in.
struct ServerRuntimeSignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let host: MachineRef
    let runtime: Runtime

    @State private var step: DaemonAPI.RuntimeSignInStep?
    @State private var byKey = false
    @State private var code = ""
    @State private var key = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var copied: String?

    private var ready: Bool {
        byKey ? !key.trimmed.isEmpty : step.map { !$0.wantsCode || !code.trimmed.isEmpty } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(RuntimeSignInWords.title(runtime.name, machine: model.hosts.label(host)))
                .appText(.reading).fontWeight(.semibold)
                .padding([.horizontal, .top], 20)
            Form {
                content
            }
            .paperForm()
            Divider()
            HStack {
                Button(byKey ? RuntimeSignInWords.useAccount : RuntimeSignInWords.useKey) { switchWay() }
                    .disabled(busy)
                Spacer()
                Button("Cancel") { leave() }
                    .keyboardShortcut(.cancelAction)
                Button(busy ? RuntimeSignInWords.signingIn
                       : byKey || step?.wantsCode == true ? RuntimeSignInWords.signIn : RuntimeSignInWords.done) {
                    Task { await finish() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ready || busy)
            }
            .padding(16)
        }
        .frame(width: 460)
        .interactiveDismissDisabled(busy)
        .task { await start() }
    }

    @ViewBuilder
    private var content: some View {
        if byKey {
            Section {
                // The label is the placeholder, as on the Remote, so the field is named for VoiceOver.
                SecureField(RuntimeSignInWords.keyLabel, text: $key, prompt: Text(RuntimeSignInWords.keyLabel))
                    .labelsHidden()
            } footer: {
                Text(RuntimeSignInWords.keyNote(runtime.id)).appText(.fine).foregroundStyle(.secondary)
            }
        } else if let step {
            Section(RuntimeSignInWords.openLink) {
                Text(step.url.absoluteString)
                    .appText(.fine).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
                HStack {
                    Button(RuntimeSignInWords.open) { openURL(step.url) }
                    Button(copied == "link" ? "Copied" : RuntimeSignInWords.copyLink) { copy(step.url.absoluteString, "link") }
                }
            }
            if let userCode = step.userCode {
                Section {
                    LabeledContent(RuntimeSignInWords.codeLabel) {
                        HStack {
                            Text(userCode).monospaced().textSelection(.enabled)
                            Button(copied == "code" ? "Copied" : "Copy") { copy(userCode, "code") }
                                .controlSize(.small)
                        }
                    }
                } header: {
                    Text(RuntimeSignInWords.typeCode)
                } footer: {
                    Text(RuntimeSignInWords.codexNote).appText(.fine).foregroundStyle(.secondary)
                }
            } else if step.wantsCode {
                Section(RuntimeSignInWords.pasteCode) {
                    TextField(RuntimeSignInWords.codeLabel, text: $code, prompt: Text(RuntimeSignInWords.codeLabel))
                        .labelsHidden()
                        .autocorrectionDisabled()
                }
            }
        } else if problem == nil {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(RuntimeSignInWords.asking(runtime.name)).foregroundStyle(.secondary)
                }
            }
        }
        if let problem {
            Section {
                Text(problem).foregroundStyle(StateTint.failure.style(or: .secondary))
                if !byKey && step == nil {
                    Button("Try Again") { Task { await start() } }
                }
            }
        }
    }

    private func start() async {
        step = nil
        code = ""
        problem = nil
        do {
            step = try await model.runtimeSignInStart(runtime.id, on: host)
        } catch {
            problem = Self.words(error)
        }
    }

    /// A sign-in left waiting is stopped on the machine.
    private func cancelStep() {
        guard let step else { return }
        Task { try? await model.runtimeSignInFinish(.init(signInID: step.signInID, cancel: true), on: host) }
    }

    private func leave() {
        cancelStep()
        dismiss()
    }

    private func switchWay() {
        cancelStep()
        step = nil
        problem = nil
        byKey.toggle()
        if !byKey { Task { await start() } }
    }

    private func finish() async {
        busy = true
        problem = nil
        defer { busy = false }
        do {
            if byKey {
                try await model.runtimeSignInKey(runtime.id, key: key.trimmed, on: host)
            } else if let step {
                try await model.runtimeSignInFinish(.init(signInID: step.signInID, code: step.wantsCode ? code.trimmed : nil),
                                                    on: host)
            }
            dismiss()
        } catch {
            problem = Self.words(error)
            // Claude starts again after a code it did not take.
            if !byKey, step?.wantsCode == true { step = nil }
        }
    }

    private func copy(_ text: String, _ what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = what
    }

    private static func words(_ error: any Error) -> String {
        (error as? JSONRPCError)?.message ?? error.localizedDescription
    }
}

extension AppModel {
    /// Sign In… on a server's Claude or Codex (#4698), as the Remote's and the web page's: the
    /// machine runs the runtime's own sign-in and gives the link to open here.
    func runtimeSignInStart(_ runtimeID: String, on host: MachineRef) async throws -> DaemonAPI.RuntimeSignInStep {
        try await client(for: host).call(DaemonAPI.Method.runtimesSignInStart, DaemonAPI.RuntimeRequest(runtimeID: runtimeID),
                                         returning: DaemonAPI.RuntimeSignInStep.self)
    }

    /// The end of that sign-in: the code Claude's page gave, nothing for Codex, or cancel.
    func runtimeSignInFinish(_ finish: DaemonAPI.RuntimeSignInFinish, on host: MachineRef) async throws {
        _ = try await client(for: host).call(DaemonAPI.Method.runtimesSignInFinish, finish, returning: RuntimeStatus.self)
        await refreshServerRuntimes(host)
    }

    /// An API key for the runtime, kept on the machine.
    func runtimeSignInKey(_ runtimeID: String, key: String, on host: MachineRef) async throws {
        _ = try await client(for: host).call(DaemonAPI.Method.runtimesSignInKey,
                                             DaemonAPI.RuntimeSignInKey(runtimeID: runtimeID, key: key),
                                             returning: RuntimeStatus.self)
        await refreshServerRuntimes(host)
    }

    /// Whether Sign In… is offered for a runtime on a server: Claude or Codex, not signed in, on
    /// a machine that signs in from a client (#3349). This Mac's daemon refuses it.
    func offersServerSignIn(_ status: RuntimeStatus, on host: MachineRef) -> Bool {
        host != .mac && status.signIn != nil && status.needsSignIn && self.host(host, has: Capability.runtimesSignIn1)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
