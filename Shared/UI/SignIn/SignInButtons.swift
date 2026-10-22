import AgentsKitCore
import AuthenticationServices
import SwiftUI

/// A button for each sign-in provider the control plane turned on (#995), each running its
/// provider's own sign-in on this device and handing back what it gave: Apple's native sheet,
/// Google in an authentication session with PKCE, GitHub by the device flow. The nonce is the
/// one this client made for the connection; the token goes only to the control plane, which
/// checks it and forgets it. The same on the Mac and the Remote.
///
/// An organisation's own providers come first (#1002, FR-026), by name: the control plane
/// runs their flow, which opens here in an authentication session that comes back on
/// `agents://oidc` with a ticket for this connection (FR-027). With claimed domains, Use an
/// Email finds the provider of the email typed.
struct SignInButtons: View {
    /// The providers on, and the org providers.
    let providers: DaemonAPI.SignInProviders
    let nonce: String
    /// The connection's org flow and email search; nil shows no org provider.
    let asking: ControlSignIn.Asking?
    /// What the sign-in gave, once signed in.
    let answered: (ControlSignIn.Answer) -> Void
    /// Why a sign-in did not finish; nothing for a cancelled one.
    let failed: (String) -> Void

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var busy: String?
    @State private var device: GitHubDeviceFlow.DeviceCode?
    @State private var github: Task<Void, Never>?
    @State private var emailShown = false
    @State private var email = ""
    @State private var emailProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if asking != nil {
                ForEach(providers.orgs) { org in
                    Button { Task { await signInWithOrg(org.id) } } label: {
                        Label(SignInWords.orgButton(org.name), systemImage: "building.2").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(busy != nil)
                }
                if providers.discover == true {
                    if emailShown {
                        emailField
                    } else {
                        Button { emailShown = true } label: {
                            Label(SignInWords.useEmail, systemImage: "envelope").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(busy != nil)
                    }
                }
            }
            ForEach(providers.turnedOn) { row in
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

    /// Use an Email: the email, then the org provider its domain sends people to (FR-011).
    private var emailField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(SignInWords.emailPlaceholder, text: $email)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    #endif
                    .onSubmit { Task { await discover() } }
                Button("Continue") { Task { await discover() } }
                    .disabled(busy != nil || !email.contains("@"))
            }
            if let emailProblem {
                Text(emailProblem).appText(.supporting).tinted(.attention).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func discover() async {
        guard let asking, busy == nil else { return }
        let typed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.contains("@") else { return }
        emailProblem = nil
        busy = "email"
        let found: DaemonAPI.SignInDiscovered
        do {
            found = try await asking.discover(typed)
        } catch {
            busy = nil
            failed(SignInToPair.words(error) ?? error.localizedDescription)
            return
        }
        busy = nil
        guard let provider = found.provider else {
            emailProblem = SignInWords.noOrgForEmail
            return
        }
        await signInWithOrg(provider, hint: typed)
    }

    /// The org provider's flow: the control plane's address, opened in an authentication
    /// session, which comes back on `agents://oidc` with the ticket or why not.
    private func signInWithOrg(_ provider: String, hint: String? = nil) async {
        guard let asking, busy == nil else { return }
        busy = provider
        defer { busy = nil }
        do {
            let start = try await asking.orgStart(provider, hint)
            // The browser's own session: a person signed in to their organisation there is not asked again.
            let callback = try await webAuthenticationSession.authenticate(
                using: start, callback: .customScheme(SignInWords.callbackScheme), additionalHeaderFields: [:])
            switch SignInWords.callback(callback) {
            case .ticket(let ticket): answered(.ticket(ticket))
            case .failed(let why): failed(why)
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            failed(SignInToPair.words(error) ?? error.localizedDescription)
        }
    }

    private func deviceCode(_ code: GitHubDeviceFlow.DeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your code").appText(.fine).foregroundStyle(.secondary)
            Text(code.userCode).appText(.title).monospaced().textSelection(.enabled)
            Text("Type it on github.com, then come back here.").appText(.supporting).foregroundStyle(.secondary)
            // One above another on iOS, so none is cut off at large text sizes (#2081).
            codeActions {
                Button("Copy Code") { Clipboard.copy(code.userCode) }
                Button("Open github.com Again") { openURL(code.verificationURI) }
                Button("Cancel", role: .cancel) {
                    github?.cancel()
                    self.device = nil
                    busy = nil
                }
            }
            // In a Form row, as Sign In… on the Remote has it: Copy Code must not cancel too.
            .rowButtons()
        }
    }

    @ViewBuilder
    private func codeActions(@ViewBuilder _ buttons: () -> some View) -> some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 10) { buttons() }
        #else
        HStack { buttons() }.controlSize(.small)
        #endif
    }

    private func apple(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
                failed("Apple gave no sign-in. Try again.")
                return
            }
            answered(.token(provider: "apple", token: token))
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
            answered(.token(provider: "google", token: token))
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
                answered(.token(provider: "github", token: token))
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
