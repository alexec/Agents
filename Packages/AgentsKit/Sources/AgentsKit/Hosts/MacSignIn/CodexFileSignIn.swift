#if canImport(Network) && canImport(Security)
import Foundation

/// Codex's own sign-in file on this Mac (`~/.codex/auth.json`, 047), read for every request
/// and renewed in place on a 401, exactly as Codex itself would.
public struct CodexFileSignIn: MacSignInSource {
    public var file: URL
    /// Where a refresh token is exchanged. A `file://` stand-in in tests.
    public var tokenEndpoint: URL

    public init(file: URL, tokenEndpoint: URL = URL(string: "https://auth.openai.com/oauth/token")!) {
        self.file = file
        self.tokenEndpoint = tokenEndpoint
    }

    /// Whether this Mac is signed in the way the relay can lend: a ChatGPT sign-in.
    public var isSignedIn: Bool { (try? current()) != nil }

    public func current() throws -> MacSignInToken {
        let object = try Self.read(file)
        guard object["auth_mode"] as? String == "chatgpt",
              let tokens = object["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, let account = tokens["account_id"] as? String
        else { throw MacSignInFailure.notSignedIn }
        return MacSignInToken(access: access, headers: ["ChatGPT-Account-Id": account])
    }

    /// Renew after `stale` was refused. If the file already holds another token, somebody
    /// (the runtime on this Mac) renewed it first: use that, and spend nothing.
    public func renew(after stale: MacSignInToken) async throws -> MacSignInToken {
        var object = try Self.read(file)
        guard var tokens = object["tokens"] as? [String: Any],
              let refresh = tokens["refresh_token"] as? String,
              let access = tokens["access_token"] as? String else { throw MacSignInFailure.notSignedIn }
        if access != stale.access { return try current() }
        let clientID = Self.claims(access)["client_id"] as? String ?? ""
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh,
            "scope": "openid profile email"])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard status == 200, let answer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = answer["access_token"] as? String else { throw MacSignInFailure.renewalRefused(status) }
        tokens["access_token"] = newAccess
        if let id = answer["id_token"] as? String { tokens["id_token"] = id }
        if let newRefresh = answer["refresh_token"] as? String { tokens["refresh_token"] = newRefresh }
        object["tokens"] = tokens
        object["last_refresh"] = RelayClock.stamp(Date())
        let out = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try out.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return try current()
    }

    /// A sign-in file the runtime on a server can start with, holding nothing secret: the
    /// account id and plan (not secrets), tokens whose signature is `standin`, and no
    /// refresh token. The relay swaps in the real token on the way out.
    public func standIn() throws -> String { try standIn(now: Date()) }

    public func standIn(now: Date) throws -> String {
        let object = try Self.read(file)
        guard object["auth_mode"] as? String == "chatgpt", let tokens = object["tokens"] as? [String: Any],
              let id = tokens["id_token"] as? String, let account = tokens["account_id"] as? String
        else { throw MacSignInFailure.notSignedIn }
        let auth = Self.claims(id)["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let kept = auth.filter { ["chatgpt_account_id", "chatgpt_plan_type", "chatgpt_user_id", "user_id"].contains($0.key) }
        let far = Int(now.timeIntervalSince1970) + 30 * 86_400
        let issued = Int(now.timeIntervalSince1970)
        let idClaims: [String: Any] = ["iss": "agents-relay-standin", "aud": "agents-relay-standin", "exp": far,
                                       "iat": issued, "email": "relay@agents.invalid",
                                       "https://api.openai.com/auth": kept]
        let accessClaims: [String: Any] = ["exp": far, "iat": issued, "https://api.openai.com/auth": kept]
        let standIn: [String: Any] = [
            "auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(),
            "tokens": ["id_token": try Self.unsigned(idClaims), "access_token": try Self.unsigned(accessClaims),
                       "refresh_token": "agents-relay-standin", "account_id": account],
            "last_refresh": RelayClock.stamp(now)]
        return String(decoding: try JSONSerialization.data(withJSONObject: standIn, options: [.sortedKeys]), as: UTF8.self)
    }

    static func read(_ file: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        else { throw MacSignInFailure.notSignedIn }
        return object
    }

    static func claims(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func unsigned(_ claims: [String: Any]) throws -> String {
        func segment(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return try segment(["alg": "none", "typ": "JWT"]) + "." + segment(claims) + ".standin"
    }
}

enum RelayClock {
    /// `2026-09-26T05:30:31.291Z`, the shape the runtime writes its own `last_refresh` in.
    static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)
            .dateSeparator(.dash).timeSeparator(.colon).timeZone(separator: .omitted))
    }
}
#endif
