import Foundation
import Testing
@testable import AgentsKitCore

/// What a client asks Google and GitHub to sign a person in (#995).
@Suite("Signing in with Google and GitHub")
struct IdentityProvidersTests {
    @Test func googleAsksForACodeWithPKCEAndTheNonce() throws {
        let flow = GoogleSignInFlow(clientID: "123-abc.apps.googleusercontent.com", nonce: "the-nonce")
        #expect(flow.callbackScheme == "com.googleusercontent.apps.123-abc")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: flow.authorizeURL, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["client_id"] == flow.clientID && items["nonce"] == "the-nonce" && items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"] == ControlCode.base64url(ControlAgreement.sha256(Data(flow.verifier.utf8))))
        #expect(items["redirect_uri"] == "com.googleusercontent.apps.123-abc:/oauth2redirect")
        #expect(items["scope"] == "openid email profile" && items["state"] == flow.state)
        // Only this flow's state gives a code.
        let back = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?code=C0DE&state=\(flow.state)")!
        #expect(try flow.code(from: back) == "C0DE")
        let other = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?code=C0DE&state=nope")!
        #expect(throws: IdentityProviders.Failure.self) { try flow.code(from: other) }
        let body = String(decoding: flow.tokenRequest(code: "C0DE").httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("code_verifier=\(flow.verifier)") && body.contains("grant_type=authorization_code"))
        #expect(!body.contains("client_secret"))
    }

    @Test func googlesAnswerGivesTheIDTokenOnly() throws {
        #expect(try GoogleSignInFlow.idToken(from: Data(#"{"id_token":"a.b.c","access_token":"x"}"#.utf8), status: 200) == "a.b.c")
        #expect(throws: IdentityProviders.Failure.self) {
            try GoogleSignInFlow.idToken(from: Data(#"{"error":"invalid_grant"}"#.utf8), status: 400)
        }
    }

    @Test func gitHubsDeviceFlowWaitsForTheToken() async throws {
        let answers = Answers([#"{"device_code":"D","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","interval":1,"expires_in":900}"#,
                               #"{"error":"authorization_pending"}"#, #"{"error":"slow_down"}"#, #"{"access_token":"ghu_x"}"#])
        let shown = Answers([])
        let token = try await GitHubDeviceFlow(clientID: "Iv1.x").run(fetch: { request in
            (Data(answers.next(request).utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, sleep: { _ in }, show: { code in shown.add(code.userCode) })
        #expect(token == "ghu_x")
        #expect(shown.said == ["ABCD-1234"])
        #expect(answers.asked.first == "https://github.com/login/device/code")
        #expect(answers.asked.dropFirst().allSatisfy { $0 == "https://github.com/login/oauth/access_token" })
    }

    @Test func gitHubsRefusalsSayWhy() {
        #expect(throws: IdentityProviders.Failure.self) { try GitHubDeviceFlow.poll(from: Data(#"{"error":"access_denied"}"#.utf8)) }
        #expect(throws: IdentityProviders.Failure.self) { try GitHubDeviceFlow.poll(from: Data(#"{"error":"expired_token"}"#.utf8)) }
        // Only an https address to open.
        #expect(throws: IdentityProviders.Failure.self) {
            try GitHubDeviceFlow.deviceCode(from: Data(#"{"device_code":"D","user_code":"U","verification_uri":"http://evil"}"#.utf8))
        }
    }

    @Test func signInWords() {
        let request = DaemonAPI.SignInRequest(request: "r", name: "Sam’s iPhone", kind: .iPhone, provider: "github", login: "sam",
                                              code: "K7M2QX", expires: Date())
        #expect(SignInWords.title(request) == "Sam’s iPhone wants to sign in as you. GitHub · sam")
        #expect(SignInWords.row(.init(provider: "google", account: "1", email: "sam@example.com")) == "Google · sam@example.com")
        #expect(SignInWords.row(.init(provider: "local", account: "k")) == "This control plane")
    }

    /// The words name the group and pane the Mac and the Remote list Sign-ins in (#2157,
    /// #2256): Control plane, as `SettingsScope.controlPlane.title` says it.
    @Test func signInWordsNameTheirPane() {
        #expect(SignInWords.signInsPlace == "Control plane ▸ Sign-ins")
        #expect(SignInWords.paneFoot.contains(SignInWords.signInsPlace))
        #expect(!SignInWords.paneFoot.contains("You ▸"))
    }

    /// Org providers (#1002, FR-026): first, by order, then the built-in ones on.
    @Test func orgProvidersComeFirstByOrder() throws {
        let json = #"{"providers":[{"provider":"google","on":true,"available":true},{"provider":"github","on":false,"available":true}],"#
            + #""orgProviders":[{"id":"b","name":"Acme Entra","order":2},{"id":"a","name":"Acme Okta","order":1}],"discover":true}"#
        let providers = try JSONDecoder().decode(DaemonAPI.SignInProviders.self, from: Data(json.utf8))
        #expect(providers.orgs.map(\.name) == ["Acme Okta", "Acme Entra"])
        #expect(providers.forScreen.providers.map(\.provider) == ["google"])
        #expect(providers.discover == true && providers.anyOn)
        #expect(providers.name(of: "a") == "Acme Okta" && providers.name(of: "gone") == "gone")
        #expect(DaemonAPI.SignInProviders(providers: []).anyOn == false)
        #expect(DaemonAPI.SignInProviders(providers: [], orgProviders: [.init(id: "a", name: "Acme Okta")]).anyOn)
        #expect(SignInWords.orgButton("Acme Okta") == "Sign in with Acme Okta")
        #expect(SignInWords.required("Acme Okta") == "Your organisation asks you to sign in with Acme Okta.")
    }

    /// The refusals in plain words (FR-029).
    @Test func refusalsNameWhatToDo() {
        let required = JSONRPCError(code: -32077, message: "Your organisation asks you to sign in with Acme Okta.",
                                    data: ["provider": "acme-okta", "name": "Acme Okta"])
        #expect(SignInWords.requiredProvider(required) == .init(id: "acme-okta", name: "Acme Okta"))
        #expect(SignInWords.requiredProvider(JSONRPCError(code: -32078, message: "x")) == nil)
        #expect(SignInWords.isSuspended(JSONRPCError(code: -32078, message: "x")))
        #expect(!SignInWords.isSuspended(ControlAuth.Refusal(.forgotten)))
        #expect(ControlAuth.Message(line: #"{"refused":{"reason":"suspended"}}"#) == .refused(.suspended))
    }

    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var left: [String]
        private(set) var asked: [String] = []
        private(set) var said: [String] = []
        init(_ answers: [String]) { left = answers }
        func next(_ request: URLRequest) -> String {
            lock.withLock {
                asked.append(request.url!.absoluteString)
                return left.isEmpty ? "{}" : left.removeFirst()
            }
        }
        func add(_ text: String) { lock.withLock { said.append(text) } }
    }
}
