import Foundation

/// The outer loop in reach of an issue, a PR or a release (#3588, spec 3579-outer-loop), as one
/// line of links under its title on its Work page, from one `lineage/walk`. Forward: the releases
/// its PRs are part of, the CI runs that built them, their deploys and the health signals seen in
/// them. Back ("what did this come from?"): the health signal an issue reports, the release and
/// deploy it was seen in, and that release's PRs and the issues they fix; a release's own PRs and
/// their issues. No pipeline screen: the pipeline is in Lineage's data and this line.
public enum Pipeline {
    public typealias Node = DaemonAPI.LineageNode

    /// How far its walk goes: issue, PR, release, deploy, health is 4 links.
    public static let depth = 4
    /// The most of one kind the line names; the rest are "2 more".
    public static let most = 3

    /// One stage on the line: its words, and its address outside Agents; nil for "2 more".
    public struct Step: Hashable, Sendable {
        public var node: Node?
        public var words: String
        public var url: URL?

        public init(node: Node?, words: String, url: URL?) {
            self.node = node
            self.words = words
            self.url = url
        }
    }

    /// The line's stages, back then forward; empty when the walk reached none.
    public static func steps(of node: Node, in g: DaemonAPI.LineageGraph) -> [Step] {
        // The nodes of a kind that are rel to (sources) or from (targets) any of these, each once,
        // in the walk's order (newest link first).
        func sources(_ rel: String, _ kind: String, _ of: [Node]) -> [Node] {
            unique(g.links.filter { $0.rel == rel && $0.from.kind == kind && of.contains($0.to) }.map(\.from))
        }
        func targets(_ rel: String, _ kind: String, _ of: [Node]) -> [Node] {
            unique(g.links.filter { $0.rel == rel && $0.to.kind == kind && of.contains($0.from) }.map(\.to))
        }
        let reported = node.kind == "issue" ? targets("reports", "health", [node]) : []
        let seenIn = targets("seen-in", "release", reported)
        let origin = node.kind == "release" ? [node] : seenIn
        let prs = sources("part-of", "pr", origin)
        let fixed = targets("fixes", "issue", prs).filter { $0 != node }
        let releases: [Node] = switch node.kind {
        case "issue": targets("part-of", "release", sources("fixes", "pr", [node])).filter { !seenIn.contains($0) }
        case "pr": targets("part-of", "release", [node])
        case "release": [node]
        default: []
        }
        let deploys = targets("deployed-as", "deploy", releases)
        let health = sources("seen-in", "health", releases + deploys).filter { !reported.contains($0) }

        return capped(reported) { "From \(words($0))" }
            + capped(seenIn) { "seen in \(WorkList.shortRef($0.ref))" }
            + capped(targets("seen-in", "deploy", reported), words)
            + capped(prs) { "PR \(WorkList.shortRef($0.ref))" }
            + capped(fixed) { WorkList.shortRef($0.ref) }
            + capped(releases.filter { $0 != node }) { "Release \(WorkList.shortRef($0.ref))" }
            + capped(sources("builds", "ci-run", releases)) { _ in "CI run" }
            + capped(deploys, words)
            + capped(health, words)
    }

    /// "TestFlight 42", "App Store 1.2.0", "Cloud Run web-42", "Sentry issue 4321": a deploy's or a
    /// health signal's name.
    static func words(_ n: Node) -> String {
        let (scheme, id) = split(n.ref)
        let last = id.split(separator: "/").last.map(String.init) ?? id
        switch (n.kind, scheme) {
        case ("deploy", "testflight"): return "TestFlight \(last)"
        case ("deploy", "appstore"): return "App Store \(last)"
        case ("deploy", "cloudrun"): return "Cloud Run \(last)"
        case ("health", "sentry"): return "Sentry issue \(last)"
        default: return "\(scheme) \(last)"
        }
    }

    /// Where a stage is outside Agents: a CI run's page, App Store Connect for a TestFlight build or
    /// an App Store version (its address needs the app's Apple ID, which the ref does not say), a
    /// Cloud Run service's revisions in the Google Cloud console (#3654), a Sentry issue on
    /// sentry.io, else the forge's page for an issue, a PR or a release.
    public static func url(_ n: Node) -> URL? {
        let (scheme, id) = split(n.ref)
        switch (n.kind, scheme) {
        case ("ci-run", "github"):
            return URL(string: "https://github.com/" + id.replacingOccurrences(of: "/actions/run/", with: "/actions/runs/"))
        case ("ci-run", "gitlab"):
            return URL(string: "https://gitlab.com/" + id.replacingOccurrences(of: "/pipelines/", with: "/-/pipelines/"))
        case ("deploy", "testflight"), ("deploy", "appstore"):
            return URL(string: "https://appstoreconnect.apple.com/apps")
        case ("deploy", "cloudrun"):
            // cloudrun:<project>/<region>/<service>/<revision>
            let parts = id.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 4, !parts.contains(where: \.isEmpty) else { return nil }
            return URL(string: "https://console.cloud.google.com/run/detail/\(parts[1])/\(parts[2])/revisions?project=\(parts[0])")
        case ("health", "sentry"):
            let parts = id.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return URL(string: "https://sentry.io/organizations/\(parts[0])/issues/\(parts[1])/")
        default:
            return WorkList.url(n)
        }
    }

    /// A ref's scheme and the rest, in the old form (#4800): the words and addresses are made from it.
    private static func split(_ full: String) -> (scheme: String, id: String) {
        let ref = WireRef.legacy(full)
        let parts = ref.split(separator: ":", maxSplits: 1)
        return parts.count == 2 ? (String(parts[0]), String(parts[1])) : ("", ref)
    }

    private static func unique(_ nodes: [Node]) -> [Node] {
        var seen = Set<Node>()
        return nodes.filter { seen.insert($0).inserted }
    }

    private static func capped(_ nodes: [Node], _ words: (Node) -> String) -> [Step] {
        let named = nodes.prefix(most).map { Step(node: $0, words: words($0), url: url($0)) }
        return nodes.count > most ? named + [Step(node: nil, words: "\(nodes.count - most) more", url: nil)] : named
    }
}
