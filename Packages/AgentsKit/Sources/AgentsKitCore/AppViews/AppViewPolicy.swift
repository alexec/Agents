import Foundation

/// What a view may reach (#187), built from its resource's `_meta.ui.csp` and nothing else.
///
/// MCP Apps (SEP-1865) has the host build the Content Security Policy from the domains the
/// server declared, fall back to its strict default when it declared none, and never allow
/// a domain that was not declared. Every renderer — the Mac's and the phone's web views,
/// and the web page's sandbox proxy — draws a view under the policy this makes, so the
/// rule is written once:
///
/// - **Nothing undeclared.** No network at all by default (`connect-src 'none'`), no
///   pictures, scripts, styles or fonts from anywhere but the view itself and `data:`.
/// - **Never loosened.** A declared entry is kept only if it is a plain origin — a scheme
///   of `https`, `wss`, `http` or `ws`, a host, at most one `*.` in front of it, and a
///   port — so nothing a server writes can smuggle in `*`, `'unsafe-eval'`, a `;` that
///   starts a directive of its own, or a whole scheme like `https:`. What is dropped is
///   said in `refused`, and the daemon's log has it.
/// - **No frames, no plugins.** `frame-src 'none'` unless frames were declared, and
///   `object-src 'none'` always. `base-uri 'self'` unless base URIs were declared, and
///   `form-action 'none'`, which the spec leaves open and the app closes.
public struct AppViewPolicy: Codable, Hashable, Sendable {
    public var connectDomains: [String]
    public var resourceDomains: [String]
    public var frameDomains: [String]
    public var baseURIDomains: [String]
    /// Entries that were declared and are not origins, so are not allowed.
    public var refused: [String]

    public init(connectDomains: [String] = [], resourceDomains: [String] = [],
                frameDomains: [String] = [], baseURIDomains: [String] = [], refused: [String] = []) {
        self.connectDomains = connectDomains
        self.resourceDomains = resourceDomains
        self.frameDomains = frameDomains
        self.baseURIDomains = baseURIDomains
        self.refused = refused
    }

    enum CodingKeys: String, CodingKey {
        case connectDomains, resourceDomains, frameDomains, baseURIDomains = "baseUriDomains", refused
    }

    /// The strict default: nothing declared.
    public static let strict = AppViewPolicy()

    /// The policy for a resource's `_meta.ui.csp`, as declared or absent.
    public init(csp: JSONValue?) {
        var refused: [String] = []
        func origins(_ key: String) -> [String] {
            var kept: [String] = []
            for value in csp?[key]?.arrayValue ?? [] {
                guard let text = value.stringValue, let origin = Self.origin(text) else {
                    refused.append(value.stringValue ?? "\(value)")
                    continue
                }
                if !kept.contains(origin) { kept.append(origin) }
            }
            return kept
        }
        self.init(connectDomains: origins("connectDomains"), resourceDomains: origins("resourceDomains"),
                  frameDomains: origins("frameDomains"), baseURIDomains: origins("baseUriDomains"))
        self.refused = refused
    }

    /// `text` as a plain origin, lower-cased, or nil when it is anything else.
    static func origin(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        let schemes = ["https://", "wss://", "http://", "ws://"]
        guard let scheme = schemes.first(where: value.hasPrefix) else { return nil }
        var rest = String(value.dropFirst(scheme.count))
        if rest.hasSuffix("/") { rest.removeLast() }
        var host = rest
        if let colon = rest.lastIndex(of: ":") {
            let port = rest[rest.index(after: colon)...]
            guard port.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(port), (1...65535).contains(number) else {
                return nil
            }
            host = String(rest[..<colon])
        }
        if host.hasPrefix("*.") { host.removeFirst(2) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !host.isEmpty, host.count <= 253,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                      && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }) else { return nil }
        return scheme + rest
    }

    /// The Content-Security-Policy, as a header's value or a `<meta>`'s content.
    public var header: String {
        func list(_ base: [String], _ extra: [String], none: Bool = false) -> String {
            let all = base + extra
            return all.isEmpty ? (none ? "'none'" : "") : all.joined(separator: " ")
        }
        let resource = resourceDomains
        return [
            "default-src 'none'",
            "script-src \(list(["'self'", "'unsafe-inline'"], resource))",
            "style-src \(list(["'self'", "'unsafe-inline'"], resource))",
            "img-src \(list(["'self'", "data:", "blob:"], resource))",
            "font-src \(list(["'self'", "data:"], resource))",
            "media-src \(list(["'self'", "data:", "blob:"], resource))",
            "connect-src \(list([], connectDomains, none: true))",
            "frame-src \(list([], frameDomains, none: true))",
            "object-src 'none'",
            "base-uri \(list(["'self'"], baseURIDomains))",
            "form-action 'none'",
        ].joined(separator: "; ")
    }

    /// One line for the log: what this view may reach.
    public var logLine: String {
        var parts: [String] = []
        if !connectDomains.isEmpty { parts.append("connect \(connectDomains.joined(separator: " "))") }
        if !resourceDomains.isEmpty { parts.append("resources \(resourceDomains.joined(separator: " "))") }
        if !frameDomains.isEmpty { parts.append("frames \(frameDomains.joined(separator: " "))") }
        if !baseURIDomains.isEmpty { parts.append("base \(baseURIDomains.joined(separator: " "))") }
        var line = parts.isEmpty ? "strict (no network)" : parts.joined(separator: "; ")
        if !refused.isEmpty { line += "; refused \(refused.joined(separator: " "))" }
        return line
    }

    /// The `csp` the spec's `sandbox-resource-ready` and `hostCapabilities.sandbox` carry:
    /// what is allowed, after the refusals.
    public var wire: JSONValue {
        var fields: [String: JSONValue] = [:]
        if !connectDomains.isEmpty { fields["connectDomains"] = .array(connectDomains.map(JSONValue.string)) }
        if !resourceDomains.isEmpty { fields["resourceDomains"] = .array(resourceDomains.map(JSONValue.string)) }
        if !frameDomains.isEmpty { fields["frameDomains"] = .array(frameDomains.map(JSONValue.string)) }
        if !baseURIDomains.isEmpty { fields["baseUriDomains"] = .array(baseURIDomains.map(JSONValue.string)) }
        return .object(fields)
    }

    // MARK: WebKit's own block

    /// A WebKit content rule list that blocks every load but the view's own, `data:`,
    /// `blob:` and `about:`, and the origins allowed here: the network side of the same
    /// policy, for the Mac and the phone, so a view is held to it even where a policy in
    /// a `<meta>` would come too late.
    public var contentRules: String {
        // One rule a scheme: a content blocker's filter has no alternation.
        var rules: [JSONValue] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
        for scheme in ["about", "data", "blob", AppViewShell.scheme] {
            rules.append(["trigger": ["url-filter": .string("^\(scheme):")], "action": ["type": "ignore-previous-rules"]])
        }
        let allowed = Array(Set(connectDomains + resourceDomains + frameDomains)).sorted()
        for origin in allowed {
            rules.append(["trigger": ["url-filter": .string(Self.filter(origin))],
                          "action": ["type": "ignore-previous-rules"]])
        }
        let data = (try? JSONEncoder().encode(JSONValue.array(rules))) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// A content-blocker URL filter for one allowed origin. `*.` allows any subdomain.
    static func filter(_ origin: String) -> String {
        guard let split = origin.range(of: "://") else { return "^$" }
        let scheme = String(origin[..<split.lowerBound])
        var host = String(origin[split.upperBound...])
        var prefix = ""
        if host.hasPrefix("*.") {
            host.removeFirst(2)
            prefix = "[a-z0-9.-]*\\."
        }
        let escaped = host.replacingOccurrences(of: ".", with: "\\.")
        // A port, or none and then the path; never a longer host that starts the same.
        let end = host.contains(":") ? "[/?#]" : "[:/?#]"
        return "^\(scheme)://\(prefix)\(escaped)\(end)"
    }

    /// A name for the compiled rule list, the same for the same policy.
    public var rulesIdentifier: String {
        let text = contentRules
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return "agents-app-view-" + String(hash, radix: 16)
    }
}
