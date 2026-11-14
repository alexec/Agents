import Foundation

/// **Deployed ↗** on a release's Work page and **Live in ↗** on a merged pull request's (#5243, spec
/// 5239-deploy-model boards 1 and 2): the same page on the web page, whose Deployed or Live in section
/// has a row for each environment, its state and since when. The Work pages are the Lead's (#5290), so
/// this is a Web + Mac link (#4937): the Mac draws this link and nothing more, and only when this Mac
/// can open the web page (`BrowserOpening.linkPage`). The Remote gets none.
public enum DeploysLink {
    /// "Deployed" on a release's page, "Live in" on a pull request's: the section's own name.
    public static func title(kind: String) -> String {
        kind == "release" ? "Deployed" : "Live in"
    }

    public static func help(kind: String) -> String {
        kind == "release"
            ? "Where this release is live, its state and since when, on the web page."
            : "Where this pull request’s change is live, and since when, on the web page."
    }

    public static let cannotOpen = "Agents can’t open the web page"

    /// The page's place, after its `#`: `/work/release/<ref>` or `/work/pr/<ref>`, the ref escaped as
    /// the page's own address escapes it (`encodeURIComponent`). Nil for another kind or no ref.
    public static func place(kind: String, ref: String) -> String? {
        guard kind == "release" || kind == "pr", !ref.isEmpty,
              let escaped = ref.addingPercentEncoding(withAllowedCharacters: component) else { return nil }
        return "/work/\(kind)/\(escaped)"
    }

    /// What `encodeURIComponent` leaves as it is.
    private static let component = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
}
