import AgentsKitCore
import AuthenticationServices
import SwiftUI

/// A button for each sign-in provider the control plane turned on (#995), each running its
/// provider's own sign-in on this device and handing back the provider and its token: Apple's
/// native sheet, Google in an authentication session with PKCE, GitHub by the device flow. The
/// nonce is the one this client made for the connection; the token goes only to the control
/// plane, which checks it and forgets it. The same on the Mac and the Remote.
struct SignInButtons: View {
    let providers: [DaemonAPI.SignInProvider]
    let nonce: String
    /// The provider and its token, once signed in.
    let signedIn: (_ provider: String, _ token: String) -> Void
    /// Why a sign-in did not finish; nothing for a cancelled one.
    let failed: (String) -> Void

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var busy: String?
    @State private var device: GitHubDeviceFlow.DeviceCode?
    @State private var github: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(providers.filter(\.on)) { row in
                switch row.provider {
                case "apple":
                    SignInWithAppleButton(.signIn) { request in
                        request.nonce = nonce
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        apple(result)
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 36)
                    .disabled(busy != nil)
                case "google":
                    Button { Task { await google(row) } } label: {
                        Label(SignInWords.button("google"), systemImage: "g.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(busy != nil || row.clientID == nil)
                case "github":
                    Button { startGitHub(row) } label: {
                        Label(SignInWords.button("github"), systemImage: "chevron.left.forwardslash.chevron.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(busy != nil || row.clientID == nil)
                default:
                    EmptyView()
                }
            }
            if let device {
                deviceCode(device)
            } else if busy != nil {
                ProgressView().controlSize(.small)
            }
        }
        .onDisappear { github?.cancel() }
    }

    private func deviceCode(_ code: GitHubDeviceFlow.DeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your code").appText(.fine).foregroundStyle(.secondary)
            Text(code.userCode).appText(.title).monospaced().textSelection(.enabled)
            Text("Type it on github.com, then come back here.").appText(.supporting).foregroundStyle(.secondary)
            HStack {
                Button("Copy Code") { Clipboard.copy(code.userCode) }
                Button("Open github.com Again") { openURL(code.verificationURI) }
                Button("Cancel", role: .cancel) {
                    github?.cancel()
                    self.device = nil
                    busy = nil
                }
            }
            .controlSize(.small)
            // In a Form row, as Sign In… on the Remote has it: Copy Code must not cancel too.
            .rowButtons()
        }
    }

    private func apple(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
                failed("Apple gave no sign-in. Try again.")
                return
            }
            signedIn("apple", token)
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            failed(error.localizedDescription)
        }
    }

    private func google(_ row: DaemonAPI.SignInProvider) async {
        guard let clientID = row.clientID else { return }
        busy = "google"
        defer { busy = nil }
        let flow = GoogleSignInFlow(clientID: clientID, nonce: nonce)
        do {
            let callback = try await webAuthenticationSession.authenticate(
                using: flow.authorizeURL, callback: .customScheme(flow.callbackScheme),
                preferredBrowserSession: .ephemeral, additionalHeaderFields: [:])
            let token = try await flow.idToken(code: flow.code(from: callback))
            signedIn("google", token)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch let error as IdentityProviders.Failure {
            failed(error.description)
        } catch {
            failed(error.localizedDescription)
        }
    }

    private func startGitHub(_ row: DaemonAPI.SignInProvider) {
        guard let clientID = row.clientID else { return }
        busy = "github"
        github = Task {
            defer {
                busy = nil
                device = nil
            }
            do {
                let token = try await GitHubDeviceFlow(clientID: clientID).run { code in
                    await MainActor.run {
                        device = code
                        Clipboard.copy(code.userCode)
                        openURL(code.verificationURI)
                    }
                }
                signedIn("github", token)
            } catch is CancellationError {
                return
            } catch let error as IdentityProviders.Failure {
                failed(error.description)
            } catch {
                if !Task.isCancelled { failed(error.localizedDescription) }
            }
        }
    }
}

/// The clipboard on the Mac and the Remote.
enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
