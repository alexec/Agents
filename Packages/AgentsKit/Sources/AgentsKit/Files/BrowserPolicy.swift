import Foundation

/// Where the browser pane may go, and what a page may not do.
///
/// Written as a pure function so it can be tested without a web view, and written to
/// refuse by default so that a scheme nobody thought about is refused rather than
/// allowed (FR-034). The app is not sandboxed, so these rules are the only gate there
/// is.
public enum BrowserPolicy {
    /// The only schemes the pane loads.
    ///
    /// `http` and `https` are the point: a dev server and documentation. `about` is
    /// for `about:blank`, which is what an empty pane is. `file` lets an artifact with
    /// a `file:` uri open here when it is a page rather than something to read as text.
    public static let allowedSchemes: Set<String> = ["http", "https", "about", "file"]

    public enum Decision: Sendable, Equatable {
        case allow
        /// Refused, with something to say to the person who clicked it.
        case refuse(String)

        public var isAllowed: Bool { if case .allow = self { return true }; return false }
    }

    public static func decide(_ url: URL?) -> Decision {
        guard let url else { return .refuse("That is not an address this can open.") }
        guard let scheme = url.scheme?.lowercased() else {
            return .refuse("That address has no scheme, so there is nothing to open.")
        }
        guard allowedSchemes.contains(scheme) else {
            // Named, because "it did nothing" is the worst answer. A `mailto:` or a
            // custom scheme is a real thing the user asked for and this pane is simply
            // not where it happens.
            return .refuse("This pane opens web pages. It will not open a \(scheme): address.")
        }
        return .allow
    }

    /// What the user typed, turned into something to load.
    ///
    /// People type `localhost:3000` and `example.com`, not `http://localhost:3000`.
    /// Taking them at their word is the whole job of this function.
    public static func url(fromTyped text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // `localhost:3000` parses as the scheme `localhost` with the path `3000`,
        // which is the oldest trap in this business. A colon followed by digits is a
        // port, not a scheme, and that is the one case worth telling apart: everything
        // else with a scheme is taken at its word, including schemes this pane will
        // then refuse.
        if let url = URL(string: trimmed), let scheme = url.scheme, !isHostAndPort(trimmed, scheme: scheme) {
            return url
        }

        // No scheme, or a host and port wearing one. Either way it means http here,
        // because this pane is pointed at local servers more than anywhere else, and a
        // local server is rarely https.
        if let url = URL(string: "http://\(trimmed)"), url.host() != nil { return url }
        return nil
    }

    /// Whether what looks like a scheme is really a host with a port after it.
    private static func isHostAndPort(_ text: String, scheme: String) -> Bool {
        // A real scheme is followed by `//` (http://x) or by something that is not a
        // bare number (mailto:someone, about:blank).
        let remainder = text.dropFirst(scheme.count + 1)
        guard !remainder.hasPrefix("//") else { return false }
        let port = remainder.prefix { $0.isNumber }
        return !port.isEmpty && (port.count == remainder.count || remainder.dropFirst(port.count).hasPrefix("/"))
    }
}
