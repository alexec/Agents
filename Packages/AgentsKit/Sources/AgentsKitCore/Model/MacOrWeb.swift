import Foundation

/// What the Remote shows where a Mac + web feature was (#2796, #2798): the Mac window and the web
/// page are full clients, and the Remote drops admin set-up and reporting. A person who looks for
/// one learns where it is, with the web page a tap away when the control plane serves one.
public enum MacOrWebWords {
    public static let line = "Open this on your Mac or the web page."
    public static let openWebPage = "Open the Web Page"

    /// The web page at `page` (`settings`, `reports`, `console/audit`): on the control plane's own
    /// domain when it serves the page there, else where its Mac serves it. Nil when it is served
    /// nowhere.
    public static func url(_ status: DaemonAPI.ControlStatus?, page: String) -> URL? {
        guard let policy = OrgPolicyWords.consoleURL(status),
              var parts = URLComponents(url: policy, resolvingAgainstBaseURL: false) else { return nil }
        parts.fragment = "/\(page)"
        return parts.url
    }
}
