import Foundation

/// Settings ▸ Browser (#3535): the machine's browser (#3533), one Chromium that agents on a
/// machine drive with a kept profile. `browser/state` says whether Chromium is downloaded,
/// its size, and the sites the profile keeps cookies for, which is how a site remembers a
/// sign-in; `browser/clear` clears one site, or all of them.
public struct BrowserState: Codable, Sendable, Hashable {
    public var installed: Bool
    public var running: Bool
    public var downloadBytes: Int64
    public var sites: [BrowserSite]
    /// Why the sites could not be read, when they could not.
    public var problem: String?

    public init(installed: Bool = false, running: Bool = false, downloadBytes: Int64 = 0,
                sites: [BrowserSite] = [], problem: String? = nil) {
        self.installed = installed
        self.running = running
        self.downloadBytes = downloadBytes
        self.sites = sites
        self.problem = problem
    }
}

/// One site with cookies in the machine's browser: its registrable domain (github.com).
public struct BrowserSite: Codable, Sendable, Hashable, Identifiable {
    public var site: String
    public var cookies: Int

    public var id: String { site }

    public init(site: String, cookies: Int) {
        self.site = site
        self.cookies = cookies
    }
}

/// browser/clear's request: one site, or every site when `site` is nil.
public struct BrowserClearRequest: Codable, Sendable, Hashable {
    public var site: String?

    public init(site: String? = nil) {
        self.site = site
    }
}

/// Settings ▸ Browser's words, the same on the Mac and the web page (Web/src/model/browserSettings.ts).
public enum BrowserSettingsWords {
    public static let title = "Browser"
    public static let symbol = "safari"
    public static let sitesHeader = "Sites with sign-ins"
    public static let sitesFooter = "Sites keep a sign-in in the browser's cookies. Agents on this machine use these sign-ins. "
        + "Clear signs agents out of that site."
    public static let noSites = "No sites yet."
    public static let notDownloaded = "Not downloaded yet. The browser downloads the first time an agent uses it."
    public static let downloadHeader = "Download"
    public static let downloadLabel = "Chromium"
    public static let notDownloadedShort = "Not downloaded"
    public static let downloadFooter = "One Chromium for this machine, which agents drive. It stops after 15 minutes with no use."
    public static let clear = "Clear"
    public static let clearAll = "Clear All\u{2026}"
    public static let clearAllQuestion = "Clear every site's sign-ins?"
    public static let clearAllDetail = "Agents on this machine are signed out of every site, and a person must sign in again."

    /// A row's Clear, said with its site, so each one is told apart.
    public static func clearSite(_ site: String) -> String { "Clear \(site)" }

    public static func cookies(_ n: Int) -> String { n == 1 ? "1 cookie" : "\(n) cookies" }

    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
