import AgentsKitCore
import SwiftUI

/// Pair with no code by signing in (#995, spec 736 FR-009): the control plane's address, then
/// a button for each provider it turned on, the organisation's own first (#1002). Apple and Google pair at once as the person the
/// sign-in names; GitHub waits for Approve on another of their clients, with a code to compare.
/// The same on the Mac's Connect sheet and the Remote's pairing screen.
struct SignInToPair: View {
    /// Pairs at `url` with the sign-in `signIn` gives, telling `waiting` the code while a GitHub
    /// sign-in waits; keeps the membership. Throws why it did not pair.
    let pair: (_ url: URL, _ signIn: @escaping ControlSignIn.Provider,
               _ waiting: @escaping @Sendable (DaemonAPI.SignInWaiting) -> Void) async throws -> Void
    /// Says a failure in words for this client.
    let sentence: (any Error) -> String
    /// Paired.
    let done: () -> Void

    @State private var address = ""
    @State private var asking: Asking?
    @State private var waitingCode: String?
    @State private var problem: String?
    @State private var attempt: Task<Void, Never>?
    /// The org provider a refusal asked for (FR-029): Continue shows only its button.
    @State private var required: DaemonAPI.SignInOrgProvider?
    /// The person's organisation turned their access off (FR-029).
    @State private var suspended = false

    /// The providers on, the nonce, the connection's org flow, and the pairing waiting for
    /// what the sign-in gives.
    struct Asking {
        var providers: DaemonAPI.SignInProviders
        var nonce: String
        var ask: ControlSignIn.Asking
        var answer: CheckedContinuation<ControlSignIn.Answer, any Error>
    }

    /// What was typed, as an address to dial: https unless it says otherwise.
    static func url(_ typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let full = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if suspended {
                Text(SignInWords.suspendedLine).appText(.supporting).tinted(.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let asking {
                SignInButtons(providers: asking.providers, nonce: asking.nonce, asking: asking.ask, answered: { answer in
                    self.asking = nil
                    asking.answer.resume(returning: answer)
                }, failed: { problem = $0 })
            } else if let waitingCode {
                Text(SignInWords.waiting(waitingCode)).appText(.supporting).fixedSize(horizontal: false, vertical: true)
                Text(waitingCode).appText(.title).monospaced()
                ProgressView().controlSize(.small)
            } else {
                HStack {
                    TextField("control.example.com", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit(start)
                    Button("Continue", action: start)
                        .disabled(Self.url(address) == nil || attempt != nil)
                    if attempt != nil { ProgressView().controlSize(.small) }
                }
            }
            if let problem {
                Text(problem).appText(.supporting).tinted(.attention).fixedSize(horizontal: false, vertical: true)
            }
            if let required, asking == nil, attempt == nil {
                Button(SignInWords.orgButton(required.name), action: start)
                    .buttonStyle(.borderedProminent)
                    .disabled(Self.url(address) == nil)
            }
            if attempt != nil, asking != nil || waitingCode != nil {
                Button("Cancel", role: .cancel, action: cancel).controlSize(.small)
            }
        }
        // One Form row on the Remote: a tap on one button fires only that one.
        .rowButtons()
        .onDisappear(perform: cancel)
    }

    private func start() {
        guard let url = Self.url(address), attempt == nil else { return }
        problem = nil
        suspended = false
        let only = required
        attempt = Task {
            do {
                try await pair(url, { providers, nonce, ask in
                    var shown = providers.forScreen
                    // Only the org provider the organisation asked for (FR-029), when it is on.
                    if let only, shown.orgs.contains(where: { $0.id == only.id }) {
                        shown = DaemonAPI.SignInProviders(providers: [], orgProviders: shown.orgs.filter { $0.id == only.id })
                    }
                    guard shown.anyOn else { throw ControlSignIn.Failure(SignInWords.noneOn) }
                    let screen = shown
                    return try await withCheckedThrowingContinuation { answer in
                        Task { @MainActor in asking = Asking(providers: screen, nonce: nonce, ask: ask, answer: answer) }
                    }
                }, { shown in
                    Task { @MainActor in waitingCode = shown.code }
                })
                guard !Task.isCancelled else { return }
                required = nil
                done()
            } catch {
                if !Task.isCancelled {
                    if let asked = SignInWords.requiredProvider(error) {
                        required = asked
                        problem = SignInWords.required(asked.name)
                    } else if SignInWords.isSuspended(error) {
                        suspended = true
                        problem = nil
                    } else {
                        problem = sentence(error)
                    }
                }
            }
            attempt = nil
            asking = nil
            waitingCode = nil
        }
    }

    private func cancel() {
        asking?.answer.resume(throwing: CancellationError())
        asking = nil
        attempt?.cancel()
        attempt = nil
        waitingCode = nil
    }
}

extension SignInToPair {
    /// A failure to sign in, in words: a refusal says why, an `s:` refused as unknown means no
    /// provider is on there.
    static func words(_ error: any Error) -> String? {
        if let refusal = error as? ControlAuth.Refusal, refusal.reason == .unknown { return SignInWords.noneOn }
        if let failure = error as? ControlSignIn.Failure { return failure.description }
        if let rpc = error as? JSONRPCError { return rpc.message }
        return nil
    }
}
