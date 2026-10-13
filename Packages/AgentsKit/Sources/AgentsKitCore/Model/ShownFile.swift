import Foundation

/// A file the agent asked the app to put in front of the user.
///
/// The other direction from everything else the files pane does. The pane is the
/// user's: they walk the folder and open what they want. This is the agent saying
/// "look at this", which the protocol has no word for either, so it arrives the same
/// way a suggested prompt does — a tool call against the MCP server the app serves.
/// `AppService` is that server, and `DaemonCore.showFile` is what answers it.
///
/// It is a request and not a command in one way that matters: nothing here writes,
/// selects or changes a file. The most it can do is open a file the agent was already
/// allowed to read, in a pane that is already read-only.
public struct ShownFile: Codable, Hashable, Sendable {
    /// Absolute, and checked against the agent's folders before any window hears
    /// about it.
    public var path: String
    /// Where to put the reader, counted from one. Nil means the top of the file.
    public var line: Int?
    /// How to draw a CSV as a chart (#836). A Vega-Lite spec says it itself.
    public var chart: ChartHint?

    public init(path: String, line: Int? = nil, chart: ChartHint? = nil) {
        self.path = path
        self.line = line
        self.chart = chart
    }

    public var url: URL { URL(filePath: path) }
    public var name: String { url.lastPathComponent }

    /// Whether the files pane will show this as a live page (022) rather than as
    /// numbered source. One list, here, so the daemon and the pane agree on it.
    public var isMarkdown: Bool { Self.isMarkdown(url) }

    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    public static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// What an agent sent, made fit to use, or nothing.
    ///
    /// Stricter than `SuggestedPrompt`, which forgives a bad entry because the row is
    /// a nicety. This one opens something, so a path that is not a path is refused
    /// rather than guessed at. A line that is zero, negative or absurd is dropped and
    /// the file still opens: being shown the right file at the wrong place is better
    /// than being shown nothing.
    public init?(wire: JSONValue?) {
        let path = (wire?["path"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return nil }
        let line = wire?["line"]?.intValue
        self.init(path: URL(filePath: path).standardizedFileURL.path,
                  line: line.flatMap { $0 >= 1 && $0 <= Self.lineLimit ? $0 : nil },
                  chart: ChartHint(wire: wire?["chart"]))
    }

    /// What the chat's card for it is (#836): a chart, a diagram (#853) and a picture
    /// show a preview.
    public enum Look: Hashable, Sendable {
        case chart
        case diagram
        case picture
        case page
        case file
    }

    public var look: Look {
        if ChartSpec.isChart(url, hint: chart) { return .chart }
        if MermaidDiagram.isMermaid(url) { return .diagram }
        if FileProbe.imageKinds.contains(url.pathExtension.lowercased()) { return .picture }
        if isMarkdown || HTMLPageScope.isHTML(url) { return .page }
        return .file
    }

    /// The card's grey line before the folder: "Bar chart", "Diagram", "Picture", "Page", "File".
    public var lookWords: String {
        switch look {
        case .chart: return chart?.mark.words ?? "Chart"
        case .diagram: return "Diagram"
        case .picture: return "Picture"
        case .page: return "Page"
        case .file: return "File"
        }
    }

    /// Past this, a line number is a mistake rather than a place. The pane shows the
    /// first 128 KB of a file; no line in that is anywhere near this.
    static let lineLimit = 10_000_000
}
