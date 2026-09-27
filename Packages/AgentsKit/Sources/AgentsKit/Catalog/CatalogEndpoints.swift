import Foundation

/// Where the catalogue and GitHub are (059, research R8).
///
/// A walk points all of GitHub at one local fixture server with `AGENTS_TEST_GITHUB_URL`,
/// and skills.sh at one with `AGENTS_TEST_CATALOG_URL`; GitHub's hosts then sit under
/// `/api`, `/raw` and `/codeload` on it, and the plain host is the base. When either is
/// set, the person's `gh` is never used, so a walk cannot reach the real GitHub through it.
struct CatalogEndpoints: Sendable, Equatable {
    var catalog: URL
    var web: URL
    var api: URL
    var raw: URL
    var codeload: URL

    static let live = CatalogEndpoints(
        catalog: URL(string: "https://skills.sh")!,
        web: URL(string: "https://github.com")!,
        api: URL(string: "https://api.github.com")!,
        raw: URL(string: "https://raw.githubusercontent.com")!,
        codeload: URL(string: "https://codeload.github.com")!)

    static let catalogVariable = "AGENTS_TEST_CATALOG_URL"
    static let githubVariable = "AGENTS_TEST_GITHUB_URL"

    static func from(environment: [String: String]) -> CatalogEndpoints {
        var out = live
        if let s = environment[catalogVariable], let url = URL(string: s) { out.catalog = url }
        if let s = environment[githubVariable], let url = URL(string: s) {
            out.web = url
            out.api = url.appending(path: "api")
            out.raw = url.appending(path: "raw")
            out.codeload = url.appending(path: "codeload")
        }
        return out
    }

    /// Whether these are the real services, which is the only time `gh` may be used.
    var isLive: Bool { self == .live }
}

/// Owners whose results carry the **known** mark (059, research R11). A mark, not a gate:
/// anything can be added, and nothing else is flagged.
enum KnownOwners {
    static let owners: Set<String> = [
        "anthropics", "openai", "google", "google-gemini", "github", "microsoft", "vercel",
        "vercel-labs", "apple", "expo", "figma", "stripe", "supabase", "cloudflare",
    ]

    static func isKnown(_ owner: String) -> Bool { owners.contains(owner.lowercased()) }
}
