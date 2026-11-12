import Foundation

/// The Console's admin pages that the Mac window does not draw, each one a link of the Web + Mac
/// link tier (#4937, #4939): Report Policy, Catalogue (Who Uses What and Approved), Read API and
/// Requests. They are in Settings ▸ Policy, below **Edit in Console**, for an admin only, and only
/// when this Mac can open the web page (`BrowserOpening.linkPage`). The Remote gets none.
///
/// Saved Views has no link of its own: it is on Reports' own list, where Cost's **Open Reports**
/// (#4938) goes.
public enum ConsoleLinks {
    public struct Link: Equatable, Sendable, Identifiable {
        /// The page's id on the web page (`Web/src/model/nav.ts`).
        public let id: String
        /// The button's words: "Report Policy in Console".
        public let title: String
        /// One line on what the page is for.
        public let about: String
        /// The place on the page, after its `#`: `/settings/reportPolicy`.
        public let place: String
    }

    public static let title = "In the Console"
    public static let foot = "These pages are only on the web page. Each one opens in your browser."

    public static let links: [Link] = [
        Link(id: "reportPolicy", title: "Report Policy in Console",
             about: "Totals Only, each group’s leads, and a budget a month for each group and the organisation.",
             place: "/settings/reportPolicy"),
        Link(id: "catalogue", title: "Catalogue in Console",
             about: "Who Uses What: the MCP servers and skills on each machine. Approved: each approval, to take back.",
             place: "/settings/catalogue"),
        Link(id: "readApi", title: "Read API in Console",
             about: "The tokens a BI tool reads the reports with, and the OTLP export.",
             place: "/settings/readApi"),
        Link(id: "requests", title: "Requests in Console",
             about: "Machines waiting to join, MCP servers and skills people ask for, and budgets they ask to raise.",
             place: "/requests/requests"),
    ]

    /// The links an admin sees: none for anyone else, and none when this Mac can open no web page.
    public static func shown(admin: Bool, status: DaemonAPI.ControlStatus?, onThisMac: Bool) -> [Link] {
        guard admin, BrowserOpening.linkPage(status, onThisMac: onThisMac) != nil else { return [] }
        return links
    }

    public static let cannotOpen = "Agents can’t open the Console"
}
