import Foundation

/// **Open in Browser** (#109), in the window and in Agents Host: what it does, decided the same
/// way in both.
///
/// - The page isn't served: say why, in the words its row uses, and open nothing.
/// - A browser of the default browser's family is paired already: open the page.
/// - Otherwise: make a browser code and open the page with it in the fragment
///   (`#code=…`), so the browser pairs in the same step. The fragment never reaches a
///   server, the page takes it out of its address at once, and the code is the pasted
///   one: one use, five minutes, good only through the listener it opens (071 R2).
public enum BrowserOpening {
    public enum Step: Equatable, Sendable {
        case notServed(String)
        case open(URL)
        case pair
    }

    /// What a press does now. `web` is what the control plane says of its page, nil when it
    /// wasn't asked to serve one; `browsers` are the names of the paired browser clients
    /// ("Chrome on Alex's Mac"); `family` is the default browser's ("Chrome"), nil when it
    /// is one the page doesn't name, which is then paired.
    public static func step(web: DaemonAPI.WebRemoteStatus?, browsers: [String], family: String?) -> Step {
        guard let web else { return .notServed(offWords) }
        guard web.served, let url = URL(string: web.address) else { return .notServed(web.summary) }
        if let family, browsers.contains(where: { $0.hasPrefix("\(family) on ") }) { return .open(url) }
        return .pair
    }

    public static let offWords = "Not serving: Serve Agents to browsers on this Mac is off in Agents Host."

    /// The page, carrying `code` in its fragment. Everything but letters, digits and `-._~`
    /// is escaped, so the code's own `:` and `%` come back whole from `decodeURIComponent`.
    public static func pairingURL(_ web: DaemonAPI.WebRemoteStatus, code: String) -> URL? {
        let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let escaped = code.addingPercentEncoding(withAllowedCharacters: plain) else { return nil }
        return URL(string: "\(web.address)/#code=\(escaped)")
    }

    /// The name the page gives a browser by its user agent (Web/src/session.ts `browserName`),
    /// from the default browser's bundle id.
    public static func family(bundleID: String?) -> String? {
        guard let id = bundleID?.lowercased() else { return nil }
        if id.hasPrefix("com.apple.safari") { return "Safari" }
        if id.hasPrefix("com.google.chrome") { return "Chrome" }
        if id.hasPrefix("com.microsoft.edgemac") { return "Edge" }
        if id.hasPrefix("org.mozilla.firefox") { return "Firefox" }
        return nil
    }
}
