import AgentsKitCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

/// Signing in to a person's MCP server, as the MCP authorization spec has it, with the app
/// as the OAuth client (#306):
///
/// 1. **Protected-resource metadata** (RFC 9728): from the `resource_metadata` the server's
///    401 named, else `/.well-known/oauth-protected-resource` with the server's path, then
///    without it. It names the authorization server and the scopes.
/// 2. **Authorization-server metadata** (RFC 8414, or OpenID Connect discovery), at the
///    well-known places the spec lists, in its order.
/// 3. **Dynamic client registration** (RFC 7591) when the server offers it, for the
///    loopback redirect this sign-in listens on. Otherwise a client the person registered
///    themselves (GitHub's has no registration).
/// 4. **Authorization code with PKCE** (S256 only) and the `resource` parameter (RFC 8707),
///    then the code exchanged for tokens, and refreshed before an agent starts.
///
/// Only the steps' outcome is ever logged, by the caller, in words: never a URL, a code, a
/// client secret or a token.
enum MCPOAuth {
    typealias HTTPSend = MCPClient.HTTPSend

    enum Failure: Error, Equatable, Sendable {
        /// Neither the server nor anything it pointed to described how to sign in.
        case noMetadata
        /// The protected-resource metadata is for some other server.
        case resourceMismatch
        /// The authorization server does not say it takes PKCE with S256.
        case noPKCE
        /// It has no registration, and the person has given no client of their own.
        case needsClient(issuer: String)
        /// The authorization server refused, in its own words (`error_description`).
        case refused(String)
        /// A refresh token it no longer takes: sign in again.
        case invalidGrant
        /// The answer was not what OAuth answers.
        case malformed
        case unreachable

        /// A sentence for the person. Never a URL or a token.
        var sentence: String {
            switch self {
            case .noMetadata: "This server doesn't say how to sign in to it."
            case .resourceMismatch: "This server's sign-in describes a different server, so the app won't use it."
            case .noPKCE: "This server's sign-in doesn't offer PKCE, which the app needs to sign in safely."
            case .needsClient: "This server's sign-in doesn't let apps register themselves. Give it a client ID you registered with it."
            case .refused(let why): why.isEmpty ? "The sign-in was refused." : "The sign-in was refused: \(why)"
            case .invalidGrant: "The sign-in has ended. Sign in again."
            case .malformed: "The sign-in answered with something the app couldn't read."
            case .unreachable: "The sign-in couldn't be reached."
            }
        }

        /// One word for the log.
        var logWord: String {
            switch self {
            case .noMetadata: "no metadata"
            case .resourceMismatch: "resource mismatch"
            case .noPKCE: "no PKCE"
            case .needsClient: "needs a client"
            case .refused: "refused"
            case .invalidGrant: "invalid grant"
            case .malformed: "malformed"
            case .unreachable: "unreachable"
            }
        }
    }

    /// RFC 9728's document, as much of it as signing in needs.
    struct ProtectedResource: Equatable, Sendable {
        var resource: String?
        var authorizationServers: [String]
        var scopes: [String]
    }

    /// RFC 8414's document, as much of it as signing in needs.
    struct AuthorizationServer: Codable, Equatable, Sendable {
        var issuer: String
        var authorizationEndpoint: String
        var tokenEndpoint: String
        var registrationEndpoint: String?
        var revocationEndpoint: String?
        var codeChallengeMethods: [String]?
        var scopes: [String]?
    }

    /// A client the app is to the authorization server: registered for one sign-in, or
    /// given by the person.
    struct Client: Codable, Equatable, Sendable {
        var id: String
        var secret: String?
        /// `client_secret_basic` sends the secret as Basic; anything else, in the form.
        var authMethod: String?
    }

    /// What a token endpoint answers with.
    struct Tokens: Equatable, Sendable {
        var access: String
        var refresh: String?
        var expiresIn: Int?
        var scope: String?
    }

    /// Where a sign-in goes, found before the browser opens.
    struct Plan: Equatable, Sendable {
        var resource: String
        var server: AuthorizationServer
        var scopes: [String]
    }

    // MARK: Discovery

    /// The server's address as a resource (RFC 8707 §2): scheme and host in lower case,
    /// no fragment, no default port. The path is kept as it was written.
    static func canonical(_ url: String) -> String? {
        guard var parts = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.fragment = nil
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        return parts.string
    }

    /// Where the protected-resource metadata may be, in the order to ask (RFC 9728 §3.1).
    static func resourceMetadataURLs(server: String, named: String?) -> [URL] {
        if let named, let url = URL(string: named) { return [url] }
        guard let parts = URLComponents(string: server), let scheme = parts.scheme, let host = parts.host else { return [] }
        let origin = "\(scheme)://\(host)" + (parts.port.map { ":\($0)" } ?? "")
        let path = parts.path == "/" ? "" : parts.path
        var urls: [URL] = []
        if !path.isEmpty, let url = URL(string: origin + "/.well-known/oauth-protected-resource" + path) { urls.append(url) }
        if let url = URL(string: origin + "/.well-known/oauth-protected-resource") { urls.append(url) }
        return urls
    }

    /// Where an issuer's metadata may be, in the MCP spec's order: OAuth with the path
    /// inserted, OpenID with it inserted, OpenID with it appended; for an issuer with no
    /// path, OAuth then OpenID.
    static func authorizationServerMetadataURLs(issuer: String) -> [URL] {
        guard let parts = URLComponents(string: issuer), let scheme = parts.scheme, let host = parts.host else { return [] }
        let origin = "\(scheme)://\(host)" + (parts.port.map { ":\($0)" } ?? "")
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        let texts = path.isEmpty
            ? [origin + "/.well-known/oauth-authorization-server", origin + "/.well-known/openid-configuration"]
            : [origin + "/.well-known/oauth-authorization-server" + path,
               origin + "/.well-known/openid-configuration" + path,
               origin + path + "/.well-known/openid-configuration"]
        return texts.compactMap(URL.init(string:))
    }

    /// `scope` from a `WWW-Authenticate` challenge, when it names one.
    static func challengeScope(_ header: String?) -> [String]? {
        guard let header,
              let range = header.range(of: #"(?<![a-z_])scope\s*=\s*("[^"]*"|[^,\s]+)"#, options: .regularExpression)
        else { return nil }
        let pair = header[range]
        guard let equals = pair.firstIndex(of: "=") else { return nil }
        let value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let scopes = value.split(separator: " ").map(String.init)
        return scopes.isEmpty ? nil : scopes
    }

    /// Find where to sign in. A server with no protected-resource metadata at all is taken
    /// to be its own authorization server (the 2025-03-26 spec's fallback).
    static func discover(server: String, resourceMetadata: String?, scope: [String]? = nil,
                         http: HTTPSend) async throws -> Plan {
        guard let resource = canonical(server) else { throw Failure.noMetadata }
        var protected: ProtectedResource?
        for url in resourceMetadataURLs(server: server, named: resourceMetadata) {
            if let json = try await getJSON(url, http: http) {
                protected = ProtectedResource(
                    resource: json["resource"]?.stringValue,
                    authorizationServers: json["authorization_servers"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                    scopes: json["scopes_supported"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                break
            }
        }
        // The metadata must be for this server: the same origin, and a path this one is in.
        if let named = protected?.resource {
            guard let mine = URLComponents(string: resource), let theirs = URLComponents(string: canonical(named) ?? ""),
                  mine.scheme == theirs.scheme, mine.host == theirs.host, mine.port == theirs.port,
                  mine.path.hasPrefix(theirs.path.hasSuffix("/") ? String(theirs.path.dropLast()) : theirs.path)
            else { throw Failure.resourceMismatch }
        }
        let issuers: [String] = {
            if let listed = protected?.authorizationServers, !listed.isEmpty { return listed }
            guard let parts = URLComponents(string: resource), let scheme = parts.scheme, let host = parts.host else { return [] }
            return ["\(scheme)://\(host)" + (parts.port.map { ":\($0)" } ?? "")]
        }()
        for issuer in issuers {
            for url in authorizationServerMetadataURLs(issuer: issuer) {
                guard let json = try await getJSON(url, http: http),
                      let authorize = json["authorization_endpoint"]?.stringValue,
                      let token = json["token_endpoint"]?.stringValue else { continue }
                let found = AuthorizationServer(
                    issuer: json["issuer"]?.stringValue ?? issuer,
                    authorizationEndpoint: authorize, tokenEndpoint: token,
                    registrationEndpoint: json["registration_endpoint"]?.stringValue,
                    revocationEndpoint: json["revocation_endpoint"]?.stringValue,
                    codeChallengeMethods: json["code_challenge_methods_supported"]?.arrayValue?.compactMap(\.stringValue),
                    scopes: json["scopes_supported"]?.arrayValue?.compactMap(\.stringValue))
                // The spec: no S256 advertised, no sign-in.
                guard found.codeChallengeMethods?.contains("S256") == true else { throw Failure.noPKCE }
                var scopes = scope ?? protected?.scopes ?? []
                if !scopes.isEmpty, found.scopes?.contains("offline_access") == true, !scopes.contains("offline_access") {
                    scopes.append("offline_access")
                }
                return Plan(resource: protected?.resource.flatMap(canonical) ?? resource, server: found, scopes: scopes)
            }
        }
        throw Failure.noMetadata
    }

    // MARK: PKCE

    /// 32 random bytes, base64url: 43 characters (RFC 7636 §4.1).
    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        #if canImport(Security)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        #else
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        #endif
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    #if canImport(CryptoKit)
    /// S256: base64url of the verifier's SHA-256 (RFC 7636 §4.2).
    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    #endif

    // MARK: Registration and the authorization request

    /// RFC 7591, as a public client of the loopback redirect.
    static func register(at endpoint: String, redirect: String, http: HTTPSend) async throws -> Client {
        guard let url = URL(string: endpoint) else { throw Failure.malformed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "client_name": "Agents",
            "redirect_uris": [.string(redirect)],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]))
        let (data, response) = try await send(request, http: http)
        guard (200..<300).contains(response.statusCode) else { throw refusal(data) }
        guard let json = try? JSONValue.parse(data), let id = json["client_id"]?.stringValue else { throw Failure.malformed }
        return Client(id: id, secret: json["client_secret"]?.stringValue,
                      authMethod: json["token_endpoint_auth_method"]?.stringValue)
    }

    static func authorizationURL(_ plan: Plan, client: Client, redirect: String, state: String,
                                 challenge: String) -> URL? {
        guard var parts = URLComponents(string: plan.server.authorizationEndpoint) else { return nil }
        var items = parts.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: plan.resource),
        ]
        if !plan.scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: plan.scopes.joined(separator: " "))) }
        parts.queryItems = items
        // `+` is a space to a form reader; a scope or a resource never means one.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url
    }

    // MARK: Tokens

    /// The code for tokens (RFC 6749 §4.1.3, with PKCE's verifier and the resource).
    static func exchange(code: String, verifier: String, redirect: String, client: Client,
                         plan: Plan, http: HTTPSend) async throws -> Tokens {
        try await token(at: plan.server.tokenEndpoint, client: client, form: [
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirect),
            ("code_verifier", verifier), ("resource", plan.resource),
        ], http: http)
    }

    /// A refresh token for fresh tokens (RFC 6749 §6). `invalidGrant` when it is no longer
    /// taken.
    static func refresh(_ refreshToken: String, tokenEndpoint: String, client: Client, resource: String,
                        http: HTTPSend) async throws -> Tokens {
        try await token(at: tokenEndpoint, client: client, form: [
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("resource", resource),
        ], http: http)
    }

    /// Best effort (RFC 7009): a sign-out still forgets the grant if this does not answer.
    static func revoke(_ token: String, at endpoint: String, client: Client, http: HTTPSend) async {
        guard let url = URL(string: endpoint) else { return }
        var request = formRequest(url, client: client, form: [("token", token)])
        request.timeoutInterval = 10
        _ = try? await send(request, http: http)
    }

    private static func token(at endpoint: String, client: Client, form: [(String, String)],
                              http: HTTPSend) async throws -> Tokens {
        guard let url = URL(string: endpoint) else { throw Failure.malformed }
        let (data, response) = try await send(formRequest(url, client: client, form: form), http: http)
        guard (200..<300).contains(response.statusCode) else { throw refusal(data) }
        let json = response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("json") == false
            ? formJSON(data) : ((try? JSONValue.parse(data)) ?? formJSON(data))
        // GitHub answers an error with a 200.
        if json["error"]?.stringValue != nil { throw refusal(data) }
        guard let access = json["access_token"]?.stringValue, !access.isEmpty else { throw Failure.malformed }
        let expires = json["expires_in"]?.intValue ?? json["expires_in"]?.stringValue.flatMap { Int($0) }
        return Tokens(access: access, refresh: json["refresh_token"]?.stringValue,
                      expiresIn: expires, scope: json["scope"]?.stringValue)
    }

    private static func formRequest(_ url: URL, client: Client, form: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        var fields = form
        if let secret = client.secret, client.authMethod == "client_secret_basic" {
            let pair = "\(formEncode(client.id)):\(formEncode(secret))"
            request.setValue("Basic \(Data(pair.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        } else {
            fields.append(("client_id", client.id))
            if let secret = client.secret { fields.append(("client_secret", secret)) }
        }
        request.httpBody = Data(fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&").utf8)
        return request
    }

    static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// `a=1&b=2` as JSON, for a token endpoint that answers in a form.
    static func formJSON(_ data: Data) -> JSONValue {
        var object: [String: JSONValue] = [:]
        for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            if parts.count == 2 { object[parts[0]] = .string(parts[1]) }
        }
        return .object(object)
    }

    private static func refusal(_ data: Data) -> Failure {
        let json = (try? JSONValue.parse(data)) ?? formJSON(data)
        if json["error"]?.stringValue == "invalid_grant" { return .invalidGrant }
        // The server's own words, shortened; never echoed to the log.
        let words = json["error_description"]?.stringValue ?? json["error"]?.stringValue ?? ""
        return .refused(String(words.prefix(200)))
    }

    private static func getJSON(_ url: URL, http: HTTPSend) async throws -> JSONValue? {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(MCPClient.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.timeoutInterval = 15
        let (data, response) = try await send(request, http: http)
        guard (200..<300).contains(response.statusCode), let json = try? JSONValue.parse(data),
              case .object = json else { return nil }
        return json
    }

    private static func send(_ request: URLRequest, http: HTTPSend) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await http(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.unreachable
        }
    }
}
