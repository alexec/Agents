import Foundation

/// Where a link on a Markdown page goes, read against the page's own file.
///
/// Foundation's Markdown reader keeps a relative link such as `other.md` or `../docs/a.md`
/// as a URL with no scheme and no base. Handed to the system as it is, macOS refuses it
/// with error -50 (a bad parameter), and the reader is left on the page with an alert.
/// Read here against the document, it names the file beside the page.
public enum MarkdownLink: Equatable, Sendable {
    /// A file on the page's host, by its full path: a relative link, an absolute path, or a
    /// `file:` link. Any `#fragment` is dropped.
    case file(URL)
    /// Only a `#fragment` of the page itself: nothing to open.
    case samePage
    /// A link with a scheme of its own (`https:`, `mailto:`, `agents:`), for the app to open.
    case other(URL)

    /// Where `link` goes, from the page whose file is `document`.
    public static func target(of link: URL, onPage document: URL) -> MarkdownLink {
        if link.isFileURL { return .file(withoutFragment(link)) }
        if link.scheme != nil { return .other(link) }
        let path = link.path(percentEncoded: false)
        if path.isEmpty { return .samePage }
        if path.hasPrefix("/") { return .file(URL(filePath: path).standardizedFileURL) }
        let folder = document.deletingLastPathComponent()
        return .file(URL(filePath: path, relativeTo: folder).standardizedFileURL.absoluteURL)
    }

    private static func withoutFragment(_ url: URL) -> URL {
        URL(filePath: url.path(percentEncoded: false)).standardizedFileURL
    }
}
