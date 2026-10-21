import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a client asks Google and GitHub to sign a person in (#995), with no screen in it: the
/// Mac and the Remote open the addresses and show the codes. Nothing here keeps a token; the
/// token goes to the control plane, which checks it and forgets it.
public enum IdentityProviders {
    /// Fetches a request: URLSession's, or a fake in tests.
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public struct Failure: Error, Sendable, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// URLSession's fetch.
    public static let urlSession: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure("No answer came back.") }
        return (data, http)
    }

    static func randomURLSafe(_ count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return ControlCode.base64url(Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func form(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }.joined(separator: "&").utf8)
    }
}

/// Google sign-in as a native app does it: the authorization code flow with PKCE in an
/// authentication session, then the code for an ID token at Google's token endpoint. The app's
/// client id is an iOS-type client, which has no secret. The ID token carries the nonce.
public struct GoogleSignInFlow: Sendable {
    public let clientID: String
    public let nonce: String
    public let verifier: String
    public let state: String

    public init(clientID: String, nonce: String) {
        self.clientID = clientID
        self.nonce = nonce
        verifier = IdentityProviders.randomURLSafe(48)
        state = IdentityProviders.randomURLSafe(16)
    }

    /// The scheme Google sends the person back on: the client id turned round.
    public var callbackScheme: String {
        let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps." + prefix
    }

    public var redirectURI: String { callbackScheme + ":/oauth2redirect" }

    public var challenge: String { ControlCode.base64url(ControlAgreement.sha256(Data(verifier.utf8))) }

    /// The address to open in the authentication session.
    public var authorizeURL: URL {
        var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return parts.url!
    }

    /// The code in the address Google sent the person back to, once its state is this flow's.
    public func code(from callback: URL) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw IdentityProviders.Failure(error == "access_denied" ? "The sign-in was cancelled." : "Google said: \(error).")
        }
        guard value("state") == state, let code = value("code"), !code.isEmpty else {
            throw IdentityProviders.Failure("Google came back with no answer for this sign-in. Try again.")
        }
        return code
    }

    /// The request that trades the code for tokens.
    public func tokenRequest(code: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = IdentityProviders.form([("client_id", clientID), ("code", code), ("code_verifier", verifier),
                                                   ("grant_type", "authorization_code"), ("redirect_uri", redirectURI)])
        return request
    }

    /// The ID token from the token endpoint's answer. The access token is not kept.
    public static func idToken(from data: Data, status: Int) throws -> String {
        let answer = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        if status == 200, let token = answer?["id_token"]?.stringValue, !token.isEmpty { return token }
        let said = answer?["error_description"]?.stringValue ?? answer?["error"]?.stringValue ?? "status \(status)"
        throw IdentityProviders.Failure("Google did not finish the sign-in (\(said)).")
    }

    /// Trades the code for the ID token.
    public func idToken(code: String, fetch: IdentityProviders.Fetch = IdentityProviders.urlSession) async throws -> String {
        let (data, response) = try await fetch(tokenRequest(code: code))
        return try Self.idToken(from: data, status: response.statusCode)
    }
}

/// GitHub sign-in by the device flow (#995, R3): the app's GitHub App client id is all it
/// needs. The person types the code on github.com; the client polls until the user token comes.
public struct GitHubDeviceFlow: Sendable {
    public struct DeviceCode: Sendable, Equatable {
        public var deviceCode: String
        public var userCode: String
        public var verificationURI: URL
        public var interval: Int
        public var expires: Date
    }

    public enum Poll: Sendable, Equatable {
        case token(String)
        case pending
        case slowDown
    }

    public let clientID: String
    /// `read:org` when an organisation is allowed (the control plane checks the membership).
    public let scopes: [String]

    public init(clientID: String, scopes: [String] = []) {
        self.clientID = clientID
        self.scopes = scopes
    }

    private func post(_ address: String, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = IdentityProviders.form(fields)
        return request
    }

    public var codeRequest: URLRequest {
        post("https://github.com/login/device/code", [("client_id", clientID), ("scope", scopes.joined(separator: " "))])
    }

    public func pollRequest(_ code: DeviceCode) -> URLRequest {
        post("https://github.com/login/oauth/access_token", [("client_id", clientID), ("device_code", code.deviceCode),
                                                            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")])
    }

    public static func deviceCode(from data: Data, now: Date = Date()) throws -> DeviceCode {
        let answer = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        guard let device = answer?["device_code"]?.stringValue, let user = answer?["user_code"]?.stringValue,
              let address = answer?["verification_uri"]?.stringValue, let uri = URL(string: address),
              uri.scheme == "https" else {
            let said = answer?["error_description"]?.stringValue ?? answer?["error"]?.stringValue ?? "no code"
            throw IdentityProviders.Failure("GitHub did not start the sign-in (\(said)).")
        }
        let interval = answer?["interval"]?.intValue ?? 5
        let expiresIn = answer?["expires_in"]?.intValue ?? 900
        return DeviceCode(deviceCode: device, userCode: user, verificationURI: uri, interval: max(interval, 1),
                          expires: now.addingTimeInterval(TimeInterval(expiresIn)))
    }

    public static func poll(from data: Data) throws -> Poll {
        let answer = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        if let token = answer?["access_token"]?.stringValue, !token.isEmpty { return .token(token) }
        switch answer?["error"]?.stringValue {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "expired_token": throw IdentityProviders.Failure("The code ran out. Sign in with GitHub again.")
        case "access_denied": throw IdentityProviders.Failure("The sign-in was cancelled on GitHub.")
        case let other?: throw IdentityProviders.Failure("GitHub did not finish the sign-in (\(other)).")
        case nil: throw IdentityProviders.Failure("GitHub did not finish the sign-in.")
        }
    }

    /// Runs the flow: `show` is given the code to type, and the user token comes back once the
    /// person approves it on github.com.
    public func run(fetch: IdentityProviders.Fetch = IdentityProviders.urlSession, now: @Sendable () -> Date = { Date() },
                    sleep: @Sendable (Int) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                    show: @Sendable (DeviceCode) async -> Void) async throws -> String {
        let (data, _) = try await fetch(codeRequest)
        let code = try Self.deviceCode(from: data, now: now())
        await show(code)
        var interval = code.interval
        while now() < code.expires {
            try await sleep(interval)
            let (answer, _) = try await fetch(pollRequest(code))
            switch try Self.poll(from: answer) {
            case .token(let token): return token
            case .pending: continue
            case .slowDown: interval += 5
            }
        }
        throw IdentityProviders.Failure("The code ran out. Sign in with GitHub again.")
    }
}
