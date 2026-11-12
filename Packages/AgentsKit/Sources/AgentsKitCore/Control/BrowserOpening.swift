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

    public static let offWords = "Not serving: Serve Agents to browsers on this Mac is off in Settings ▸ Control plane."

    /// The page, carrying `code` in its fragment. Everything but letters, digits and `-._~`
    /// is escaped, so the code's own `:` and `%` come back whole from `decodeURIComponent`.
    /// With a `place` (a link of the Web + Mac link tier, #4937), the page goes there once it
    /// has paired: `#code=…&to=<place>`, escaped the same way.
    public static func pairingURL(_ web: DaemonAPI.WebRemoteStatus, code: String, place: String? = nil) -> URL? {
        guard let escaped = escape(code) else { return nil }
        guard let place else { return URL(string: "\(web.address)/#code=\(escaped)") }
        guard let to = escape(place) else { return nil }
        return URL(string: "\(web.address)/#code=\(escaped)&to=\(to)")
    }

    /// The page at `address`, at `place` (`/reports/spend?range=week`) when there is one.
    public static func pageURL(_ address: String, place: String?) -> URL? {
        let base = address.hasSuffix("/") ? String(address.dropLast()) : address
        guard let place else { return URL(string: base) }
        return URL(string: "\(base)/#\(place)")
    }

    /// The page a link of the Web + Mac link tier opens (#4937): this Mac's own page when the
    /// control plane runs here and serves it, else the page on the control plane's own domain.
    /// Nil when this Mac can open neither, and then there is no link.
    public static func linkPage(_ status: DaemonAPI.ControlStatus?, onThisMac: Bool) -> String? {
        guard let status else { return nil }
        if onThisMac, let web = status.web, web.served, !web.address.isEmpty { return web.address }
        if let page = status.publicWeb, !page.isEmpty { return page }
        return nil
    }

    private static func escape(_ text: String) -> String? {
        let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: plain)
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

/// **Open Reports** on Cost (#4938): Reports ▸ Spend on the web page, in the Me scope and the
/// range the Cost page shows. Reports is a Web + Mac link feature (#4937): the Mac draws this link
/// and nothing more.
public enum ReportsLink {
    public static let title = "Open Reports"
    public static let help = "Reports on the web page, in the range shown here"

    /// The place on the page, after its `#`: `/reports/spend?range=week`. Me is the page's own
    /// first scope, so the link names none; a member who leads a group or an admin picks a
    /// wider one there.
    public static func place(range: UsageChart.Range) -> String {
        "/reports/spend?range=\(reportRange(range))"
    }

    /// The range's name on the wire (`ReportRange`).
    public static func reportRange(_ range: UsageChart.Range) -> String {
        switch range {
        case .day: "day"
        case .week: "week"
        case .month: "month"
        case .threeMonths: "threeMonths"
        }
    }
}
