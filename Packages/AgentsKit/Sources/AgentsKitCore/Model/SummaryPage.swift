import Foundation

/// One saved page of the daily summary (#3721), in `~/.agents/summaries` on the host: the
/// sidebar's Summary row and the Summary page. `summaries/list` has them newest first,
/// `summaries/read` reads one and `summaries/changed` says when they changed.
public struct SummaryPage: Codable, Sendable, Hashable, Identifiable {
    /// The file's name without `.md`, such as `2026-11-06-1810`: what `summaries/read` names.
    public var name: String
    /// The page's first heading, such as "Daily summary, Fri 6 Nov".
    public var title: String
    public var savedAt: Date
    /// Nobody has read it since it was saved: the Summary row's dot.
    public var unread: Bool
    /// The Daily summary workflow's session that wrote it: "How this was written".
    public var writer: UUID?

    public var id: String { name }

    public init(name: String, title: String, savedAt: Date, unread: Bool = false, writer: UUID? = nil) {
        self.name = name
        self.title = title
        self.savedAt = savedAt
        self.unread = unread
        self.writer = writer
    }
}

/// `summaries/read` (#3721): a saved page and its Markdown.
public struct SummaryPageText: Codable, Sendable, Hashable {
    public var page: SummaryPage
    public var markdown: String

    public init(page: SummaryPage, markdown: String) {
        self.page = page
        self.markdown = markdown
    }
}

/// `summaries/read`'s request: the page, as `SummaryPage.name` says it.
public struct SummaryReadRequest: Codable, Sendable, Hashable {
    public var name: String

    public init(name: String) { self.name = name }
}

public extension DailySummarySettings.Mode {
    /// Whether the daily summary writes pages: the sidebar's Summary row shows only then.
    var writesPages: Bool { self != .off }
}
