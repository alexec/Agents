import AgentsKitCore
import SwiftUI
import UIKit

/// Sign In… on a server's Claude or Codex (#4035), as the web page's RuntimeSignInDialog
/// (#3349): the machine has no browser, so the runtime's own sign-in runs there and gives a
/// link to open here. Claude's page then gives a code to paste back; Codex gives a code to
/// type on its page. An API key is the other way in.
struct RuntimeSignInSheet: View {
    @Environment(RemoteModel.self) private var model
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

    private var machine: String { model.machineName(host) }
    private var ready: Bool {
        byKey ? !key.trimmed.isEmpty : step.map { !$0.wantsCode || !code.trimmed.isEmpty } ?? false
    }

    var body: some View {
        NavigationStack {
            Form {
                if byKey {
                    Section {
                        SecureField(RuntimeSignInWords.keyLabel, text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text(RuntimeSignInWords.keyNote(runtime.id))
                    }
                } else if let step {
                    Section(RuntimeSignInWords.openLink) {
                        Button(RuntimeSignInWords.open) { openURL(step.url) }
                        Button(copied == "link" ? "Copied" : RuntimeSignInWords.copyLink) { copy(step.url.absoluteString, "link") }
                    }
                    if let userCode = step.userCode {
                        Section {
                            LabeledContent(RuntimeSignInWords.codeLabel) {
                                Text(userCode).monospaced().textSelection(.enabled)
                            }
                            Button(copied == "code" ? "Copied" : "Copy") { copy(userCode, "code") }
                        } header: {
                            Text(RuntimeSignInWords.typeCode)
                        } footer: {
                            Text(RuntimeSignInWords.codexNote)
                        }
                    } else if step.wantsCode {
                        Section(RuntimeSignInWords.pasteCode) {
                            TextField(RuntimeSignInWords.codeLabel, text: $code)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                } else if problem == nil {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(RuntimeSignInWords.asking(runtime.name)).foregroundStyle(Paper.secondary)
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
                Section {
                    Button(byKey ? RuntimeSignInWords.useAccount : RuntimeSignInWords.useKey) { switchWay() }
                        .disabled(busy)
                }
            }
            .navigationTitle(RuntimeSignInWords.title(runtime.name, machine: machine))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { leave() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? RuntimeSignInWords.signingIn
                           : byKey || step?.wantsCode == true ? RuntimeSignInWords.signIn : RuntimeSignInWords.done) {
                        Task { await finish() }
                    }
                    .disabled(!ready || busy)
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .task { await start() }
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
        UIPasteboard.general.string = text
        copied = what
    }

    private static func words(_ error: any Error) -> String {
        (error as? JSONRPCError)?.message ?? error.localizedDescription
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
