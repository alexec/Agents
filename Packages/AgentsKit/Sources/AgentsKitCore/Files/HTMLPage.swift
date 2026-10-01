import Foundation

/// An HTML file in the files pane, drawn as a page (#67), and everything it may reach.
///
/// The page is what an agent wrote, so it is treated as untrusted. The window reads
/// every file through the host (`files/read`), so it has bytes rather than a file URL to
/// give WebKit. The page is put at an address of its own, `agents-page://folder/<path>`,
/// where the path is the file's place under the agent's folder, and every stylesheet,
/// picture or script it names beside it comes back to the app as a request on that
/// scheme. This is the one place that says which of those requests are answered, and
/// with what, so the Mac and the phone draw the same page from the same rules, for a
/// project on this Mac and one on a server alike.
///
/// What the web view itself is allowed (no network, no scripts unless the person allows
/// them, nothing kept, no bridge to native code) is in `Shared/UI/Page/HTMLPage.swift`.
public struct HTMLPageScope: Sendable, Hashable {
    /// The scheme the page and its files are served on. Nothing else is: there is no
    /// `file:` access and no network.
    public static let scheme = "agents-page"
    /// One fixed host, so every file under the folder is one origin and a page's
    /// relative links resolve against it as they would on disk.
    public static let host = "folder"

    /// The folder requests are answered from, as an absolute path with no trailing
    /// slash. Nothing above it is ever read.
    public let root: String

    /// The agent's folder when the file is in it, else the file's own folder: a file
    /// opened from outside reaches only what is beside it.
    public init(file: URL, agentFolder: URL) {
        let folder = FileTree.key(agentFolder.standardizedFileURL)
        let path = FileTree.key(file.standardizedFileURL)
        if path.hasPrefix(folder + "/") {
            root = folder
        } else {
            root = FileTree.key(file.standardizedFileURL.deletingLastPathComponent())
        }
    }

    public init(root: String) {
        self.root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
    }

    /// Whether this is a file the pane draws as a page rather than as source.
    public static func isHTML(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    public static let extensions: Set<String> = ["html", "htm"]

    // MARK: Addresses

    /// Where the page for this file is put, or nil for a file outside the scope.
    public func address(of path: String) -> URL? {
        let path = FileTree.key(URL(filePath: path).standardizedFileURL)
        guard path.hasPrefix(root == "/" ? "/" : root + "/") else { return nil }
        let relative = path.dropFirst(root == "/" ? 1 : root.count + 1)
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = Self.host
        parts.path = "/" + relative
        return parts.url
    }

    /// Why a request was not answered, in words for the log and the page's console.
    public enum Refusal: Error, Sendable, Equatable {
        /// Not this scheme, or not its one host.
        case notThisPage
        /// A `..` in the path, written or percent-encoded. Never followed, even when it
        /// would land back inside: a path that climbs is refused rather than resolved.
        case climbs
        /// Nothing named, or a name no file can have.
        case malformed
    }

    /// The file a request names, as an absolute path inside `root`, or why not.
    ///
    /// The path is decoded first and split after, so an encoded slash or dot cannot
    /// smuggle a step up past the check.
    public func path(for url: URL) -> Result<String, Refusal> {
        guard url.scheme?.lowercased() == Self.scheme, url.host()?.lowercased() == Self.host else {
            return .failure(.notThisPage)
        }
        let decoded = url.path(percentEncoded: false)
        guard !decoded.contains("\0") else { return .failure(.malformed) }
        // The raw form as well: a `%2E%2E` that a URL parser left encoded is still a
        // step up once it is decoded.
        let raw = url.path(percentEncoded: true).removingPercentEncoding ?? ""
        let parts = decoded.split(separator: "/", omittingEmptySubsequences: true)
        if parts.contains("..") || raw.split(separator: "/").contains("..") { return .failure(.climbs) }
        let kept = parts.filter { $0 != "." }
        guard !kept.isEmpty else { return .failure(.malformed) }
        return .success((root == "/" ? "" : root) + "/" + kept.joined(separator: "/"))
    }

    // MARK: Answers

    /// What a request on the page's scheme is answered with.
    public enum Answer: Sendable, Equatable {
        case file(Data, mimeType: String, isText: Bool)
        /// An HTTP status, so the page sees a failed load rather than an empty file.
        case refused(status: Int, reason: String)
    }

    /// Answer one request: the scope first, then the host's own read, which checks the
    /// path against the agent's folders again on its side.
    ///
    /// A text file cut at the read limit is refused rather than sent half: half a
    /// stylesheet is a broken page, and half a script is worse. A file that is neither
    /// text nor a picture the host will carry is refused too, by name.
    public func answer(_ url: URL,
                       read: @Sendable (String) async throws -> FileReading) async -> Answer {
        let path: String
        switch self.path(for: url) {
        case .success(let found): path = found
        case .failure(.notThisPage): return .refused(status: 400, reason: "Not a page address.")
        case .failure(.climbs): return .refused(status: 403, reason: "A path that climbs out of the folder is not followed.")
        case .failure(.malformed): return .refused(status: 400, reason: "Nothing is named there.")
        }
        do {
            switch try await read(path) {
            case .text(let text, let isTruncated, let size, _):
                guard !isTruncated else {
                    return .refused(status: 413, reason: "\(URL(filePath: path).lastPathComponent) is \(size) bytes, more than the pane reads.")
                }
                return .file(Data(text.utf8), mimeType: Self.mimeType(for: path, isText: true), isText: true)
            case .image(let bytes, _, _):
                return .file(bytes, mimeType: Self.mimeType(for: path, isText: false), isText: false)
            case .other(let describedAs, _, _):
                return .refused(status: 415, reason: "\(describedAs) is not carried to the page.")
            case .unchanged:
                // Never asked for: a page's request names no stamp.
                return .refused(status: 500, reason: "The host sent nothing.")
            }
        } catch let error as JSONRPCError {
            // The host's own refusal (gone, outside the agent's folders) in its words.
            return .refused(status: error.code == DaemonAPI.Failure.fileGone ? 404 : 403, reason: error.message)
        } catch {
            return .refused(status: 504, reason: "\(URL(filePath: path).lastPathComponent) could not be read.")
        }
    }

    static func mimeType(for path: String, isText: Bool) -> String {
        let ext = URL(filePath: path).pathExtension.lowercased()
        if let known = mimeTypes[ext] { return known }
        return isText ? "text/plain" : "application/octet-stream"
    }

    private static let mimeTypes: [String: String] = [
        "html": "text/html", "htm": "text/html", "css": "text/css",
        "js": "text/javascript", "mjs": "text/javascript", "json": "application/json",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "bmp": "image/bmp", "ico": "image/x-icon",
        "tif": "image/tiff", "tiff": "image/tiff", "heic": "image/heic",
        "txt": "text/plain", "xml": "application/xml", "csv": "text/csv", "md": "text/markdown",
    ]

    // MARK: Links

    /// What a click on a link in the page does. Nothing ever loads in the file view but
    /// the file itself.
    public enum LinkDecision: Sendable, Equatable {
        /// A link to a place on this same page: the page scrolls, nothing loads.
        case stay
        /// Another file under the folder: opened in the files pane, as a click on its
        /// row would.
        case openFile(String)
        /// The web or mail: handed to the Browser pane or the default app, outside.
        case openOutside(URL)
        /// Anything else, refused without a word: a `javascript:` or `data:` address,
        /// or a path that climbs.
        case ignore
    }

    public func decide(link: URL?, on page: URL) -> LinkDecision {
        guard let link, let scheme = link.scheme?.lowercased() else { return .ignore }
        switch scheme {
        case Self.scheme:
            if link.fragment != nil, Self.withoutFragment(link) == Self.withoutFragment(page) { return .stay }
            guard case .success(let path) = path(for: link) else { return .ignore }
            return .openFile(path)
        case "http", "https", "mailto":
            return .openOutside(link)
        default:
            return .ignore
        }
    }

    private static func withoutFragment(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        return parts?.string ?? url.absoluteString
    }

    // MARK: The network

    /// A WebKit content rule list that blocks every load but the page's own scheme:
    /// no remote stylesheet, picture, font, script, fetch or socket, whether or not
    /// scripts are allowed. `data:` and `blob:` are let through, being in the page
    /// already: a report with its charts inlined as `data:` pictures is common, and
    /// reaches nothing. Compiled once by the view that draws the page.
    public static let contentRules = """
        [
          {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^\(scheme):"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^blob:"}, "action": {"type": "ignore-previous-rules"}}
        ]
        """
}
