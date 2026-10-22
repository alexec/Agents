import AgentsKitCore
import SwiftUI

/// Pair with no code by signing in (#995, spec 736 FR-009): the control plane's address, then
/// a button for each provider it turned on. Apple and Google pair at once as the person the
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

    /// The providers on, the nonce, and the pairing waiting for the token.
    struct Asking {
        var providers: [DaemonAPI.SignInProvider]
        var nonce: String
        var answer: CheckedContinuation<(provider: String, token: String), any Error>
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
            if let asking {
                SignInButtons(providers: asking.providers, nonce: asking.nonce, signedIn: { provider, token in
                    self.asking = nil
                    asking.answer.resume(returning: (provider, token))
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
        attempt = Task {
            do {
                try await pair(url, { providers, nonce in
                    guard !providers.turnedOn.isEmpty else { throw ControlSignIn.Failure(SignInWords.noneOn) }
                    return try await withCheckedThrowingContinuation { answer in
                        Task { @MainActor in asking = Asking(providers: providers.turnedOn, nonce: nonce, answer: answer) }
                    }
                }, { shown in
                    Task { @MainActor in waitingCode = shown.code }
                })
                guard !Task.isCancelled else { return }
                done()
            } catch {
                if !Task.isCancelled { problem = sentence(error) }
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
