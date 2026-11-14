import Foundation

/// **Build trends ↗** on the Pipeline line of a PR's or a release's Work page (#5180, spec 5166
/// board 5): Reports ▸ Planning ▸ Builds on the web page, opened at the CI run the line names.
/// Builds is a Web + Mac link feature (#4937): the Mac draws this link and nothing more, and only
/// when this Mac can open the web page (`BrowserOpening.linkPage`). The Remote gets none.
public enum BuildTrendsLink {
    public static let title = "Build trends"

    /// The link's help: "Build trends on the web page, at this pull request's last run on main."
    public static func help(kind: String) -> String {
        kind == "release"
            ? "Build trends on the web page, at this release’s CI run."
            : "Build trends on the web page, at this pull request’s last run on main."
    }

    public static let cannotOpen = "Agents can’t open Build trends"

    /// The run the link opens: the line's first CI run, the newest one lineage links.
    public static func run(in nodes: [DaemonAPI.LineageNode]) -> DaemonAPI.LineageNode? {
        nodes.first { $0.kind == "ci-run" }
    }

    /// The place on the page, after its `#`:
    /// `/reports/value/builds?repo=github:alexec/agents&range=month&drill=github:run:alexec/agents%23123`,
    /// the run's drill-down, whose own link goes back to the trend. Nil for a run whose ref names
    /// no repository. The run ref's `#` is escaped, as the page's own address escapes it.
    public static func place(run: DaemonAPI.LineageNode) -> String? {
        guard let ref = WireRef(lineageKind: "ci-run", ref: run.ref), ref.type == "run", !ref.topic.isEmpty
        else { return nil }
        let repo = "\(ref.provider):\(ref.topic)"
        let drill = ref.description.replacingOccurrences(of: "#", with: "%23")
        return "/reports/value/builds?repo=\(repo)&range=month&drill=\(drill)"
    }
}
