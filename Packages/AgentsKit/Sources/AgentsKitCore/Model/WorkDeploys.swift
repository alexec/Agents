import Foundation

// MARK: - The wire (#5262, #5270)

// The deploy model's types (`Packages/Wire/schema/core.schema.json`), as far as Work ▸ Deploys
// reads them: Swift decodes the fields it draws and leaves the rest (checks, rawState).

public extension DaemonAPI {
    /// An environment's tier, GitLab's five (#5262); one this build does not know reads as `other`.
    enum EnvironmentTier: String, Codable, Sendable, Hashable, CaseIterable {
        case production, staging, testing, development, other

        public init(from decoder: any Decoder) throws {
            self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .other
        }
    }

    /// A deploy's state (#5262): every system's states map to these five.
    enum DeployState: String, Codable, Sendable, Hashable {
        case waiting, running, succeeded, failed, cancelled
    }

    struct DeployArtifact: Codable, Sendable, Hashable {
        public var kind: String
        public var system: String
        public var id: String
        public var ref: String?

        public init(kind: String, system: String, id: String, ref: String? = nil) {
            self.kind = kind
            self.system = system
            self.id = id
            self.ref = ref
        }
    }

    struct DeployVersion: Codable, Sendable, Hashable {
        public var artifacts: [DeployArtifact]
        public var name: String?
        public var ref: String?

        public init(artifacts: [DeployArtifact], name: String? = nil, ref: String? = nil) {
            self.artifacts = artifacts
            self.name = name
            self.ref = ref
        }
    }

    struct DeployComponent: Codable, Sendable, Hashable {
        public var kind: String?
        public var system: String
        public var id: String
        public var name: String?
        public var repo: String?

        public init(kind: String? = nil, system: String, id: String, name: String? = nil, repo: String? = nil) {
            self.kind = kind
            self.system = system
            self.id = id
            self.name = name
            self.repo = repo
        }
    }

    struct DeployEnvironment: Codable, Sendable, Hashable {
        public var system: String
        public var name: String
        public var tier: EnvironmentTier
        public var ephemeral: Bool?
        public var url: String?

        public init(system: String, name: String, tier: EnvironmentTier, ephemeral: Bool? = nil, url: String? = nil) {
            self.system = system
            self.name = name
            self.tier = tier
            self.ephemeral = ephemeral
            self.url = url
        }
    }

    struct DeployTarget: Codable, Sendable, Hashable {
        public var component: DeployComponent
        public var environment: DeployEnvironment
        public var labels: [String: String]?

        public init(component: DeployComponent, environment: DeployEnvironment, labels: [String: String]? = nil) {
            self.component = component
            self.environment = environment
            self.labels = labels
        }
    }

    /// One try to put a version into a target (#5262).
    struct Deploy: Codable, Sendable, Hashable {
        public var system: String
        public var id: String
        public var ref: String?
        public var target: DeployTarget
        public var version: DeployVersion
        public var state: DeployState
        public var started: Date?
        public var finished: Date?
        public var rollback: Bool?
        public var share: Double?
        public var url: String?

        public init(system: String, id: String, ref: String? = nil, target: DeployTarget, version: DeployVersion,
                    state: DeployState, started: Date? = nil, finished: Date? = nil, rollback: Bool? = nil,
                    share: Double? = nil, url: String? = nil) {
            self.system = system
            self.id = id
            self.ref = ref
            self.target = target
            self.version = version
            self.state = state
            self.started = started
            self.finished = finished
            self.rollback = rollback
            self.share = share
            self.url = url
        }
    }

    /// A deploy on its target (#5270): a live one has `since` and `share`; `release` is its
    /// release's lineage ref, for the release's page.
    struct DeployOnTarget: Codable, Sendable, Hashable {
        public var deploy: Deploy
        public var release: String?
        public var since: Date?
        public var share: Double?

        public init(deploy: Deploy, release: String? = nil, since: Date? = nil, share: Double? = nil) {
            self.deploy = deploy
            self.release = release
            self.since = since
            self.share = share
        }
    }

    /// One target: its live versions, the most traffic first, and its next deploys, oldest first.
    struct DeployTargetNow: Codable, Sendable, Hashable {
        public var target: DeployTarget
        public var live: [DeployOnTarget]
        public var next: [DeployOnTarget]

        public init(target: DeployTarget, live: [DeployOnTarget] = [], next: [DeployOnTarget] = []) {
            self.target = target
            self.live = live
            self.next = next
        }
    }

    struct DeployTargetsRequest: Codable, Sendable, Hashable {
        public init() {}
    }

    /// `deploys/targets` (#5270): every target a host keeps deploys of; `at` is when it was read.
    struct DeployTargets: Codable, Sendable, Hashable {
        public var targets: [DeployTargetNow]
        public var at: Date

        public init(targets: [DeployTargetNow], at: Date) {
            self.targets = targets
            self.at = at
        }
    }
}

public extension DaemonAPI.Method {
    /// `DeployTargetsRequest` → `DeployTargets` (#5270).
    static let deploysTargets = "deploys/targets"
}

// MARK: - The page (#5270, spec 5239-deploy-model board 4)

/// Work ▸ Deploys (#5270): every component in every environment. The columns are the
/// environments in tier order (testing, then production), the rows the components, each cell
/// the targets of that component there. The web page's `model/workDeploys.ts` is the same.
public enum WorkDeploys {
    /// A column: an environment, with its tier.
    public struct Column: Hashable, Sendable, Identifiable {
        public var name: String
        public var tier: DaemonAPI.EnvironmentTier
        public var id: String { name }
    }

    /// A row: a component, with each column's targets (none where it does not run).
    public struct Row: Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var cells: [[DaemonAPI.DeployTargetNow]]
    }

    public struct Grid: Hashable, Sendable {
        public var columns: [Column]
        public var rows: [Row]
        public var isEmpty: Bool { rows.isEmpty }
    }

    /// The order of the columns: the tiers before production, then production; other with the
    /// tiers before production, after staging.
    public static func rank(_ tier: DaemonAPI.EnvironmentTier) -> Int {
        switch tier {
        case .development: 0
        case .testing: 1
        case .staging: 2
        case .other: 3
        case .production: 4
        }
    }

    public static func componentName(_ c: DaemonAPI.DeployComponent) -> String {
        if let name = c.name, !name.isEmpty { return name }
        return c.id
    }

    /// What tells a target apart: its component, its environment and its labels.
    public static func key(_ t: DaemonAPI.DeployTarget) -> String {
        let labels = (t.labels ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "\(t.component.system):\(t.component.id)@\(t.environment.name)/\(labels)"
    }

    /// The newest time a target says: its newest live deploy's since, or a next deploy's start.
    static func newest(_ t: DaemonAPI.DeployTargetNow) -> Date {
        let times = t.live.compactMap { $0.since ?? $0.deploy.finished } + t.next.compactMap { $0.deploy.started }
        return times.max() ?? .distantPast
    }

    /// Several machines' answers as one: a target that two machines keep is the one whose news
    /// is newer; the first machine's on a tie.
    public static func merge(_ answers: [[DaemonAPI.DeployTargetNow]]) -> [DaemonAPI.DeployTargetNow] {
        var order: [String] = []
        var byKey: [String: DaemonAPI.DeployTargetNow] = [:]
        for answer in answers {
            for t in answer {
                let k = key(t.target)
                if let had = byKey[k] {
                    if newest(t) > newest(had) { byKey[k] = t }
                } else {
                    order.append(k)
                    byKey[k] = t
                }
            }
        }
        return order.compactMap { byKey[$0] }
    }

    public static func grid(_ targets: [DaemonAPI.DeployTargetNow]) -> Grid {
        var tiers: [String: DaemonAPI.EnvironmentTier] = [:]
        for t in targets where tiers[t.target.environment.name] == nil {
            tiers[t.target.environment.name] = t.target.environment.tier
        }
        let columns = tiers.map { Column(name: $0.key, tier: $0.value) }.sorted {
            rank($0.tier) != rank($1.tier) ? rank($0.tier) < rank($1.tier) : $0.name < $1.name
        }
        var components: [String: (name: String, targets: [DaemonAPI.DeployTargetNow])] = [:]
        for t in targets {
            let id = "\(t.target.component.system):\(t.target.component.id)"
            components[id, default: (componentName(t.target.component), [])].targets.append(t)
        }
        let rows = components.map { id, c in
            Row(id: id, name: c.name, cells: columns.map { col in
                c.targets.filter { $0.target.environment.name == col.name }.sorted { labelsLine($0.target) < labelsLine($1.target) }
            })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Grid(columns: columns, rows: rows)
    }

    // MARK: Words

    public static let title = "Deploys"
    public static let emptyTitle = "No deploys yet"
    public static let emptyLine = "A deploy shows here once a forge's job deploys, as GitHub's and GitLab's environments record it."
    public static let noMachine = "No machine keeps deploys yet. Update Agents on a machine to see them."
    public static let none = "–"
    public static let live = "Live"
    public static let rollback = "Rollback"
    public static let noLive = "Nothing live"

    /// A version as a cell says it: its name, else its commit's first 7, else its first artifact.
    public static func versionWords(_ v: DaemonAPI.DeployVersion) -> String {
        if let name = v.name, !name.isEmpty { return name }
        if let commit = v.artifacts.first(where: { $0.kind == "commit" }) { return String(commit.id.prefix(7)) }
        return v.artifacts.first?.id ?? "?"
    }

    /// A share of the traffic, shown only when the target splits it: "90 %".
    public static func shareWords(_ share: Double?) -> String? {
        guard let share, share < 100 else { return nil }
        return share.rounded() == share ? "\(Int(share)) %" : String(format: "%.1f %%", share)
    }

    /// The target's labels (region, cluster), as one line: "region eu · cluster b"; nil with none.
    public static func labelsLine(_ t: DaemonAPI.DeployTarget) -> String {
        (t.labels ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
    }

    /// "since 8 Nov, 10:51".
    public static func sinceWords(_ date: Date, timeZone: TimeZone = .current) -> String {
        "since " + stamp(date, timeZone: timeZone)
    }

    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "8 Nov, 10:51", the same on the web page (`model/workDeploys.ts`).
    static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.day, .month, .hour, .minute], from: date)
        return String(format: "%d %@, %02d:%02d", c.day ?? 1, months[(c.month ?? 1) - 1], c.hour ?? 0, c.minute ?? 0)
    }

    /// "next: v0.20.0, waiting", for each next deploy.
    public static func nextWords(_ next: DaemonAPI.DeployOnTarget) -> String {
        "next: \(versionWords(next.deploy.version)), \(next.deploy.state == .waiting ? "waiting" : "running")"
    }

    /// The tier's chip in a column's header: only production has one, as board 4 draws it.
    public static func tierChip(_ tier: DaemonAPI.EnvironmentTier) -> String? {
        tier == .production ? "production" : nil
    }

    /// What a screen reader says for a cell.
    public static func cellLabel(component: String, environment: String, _ targets: [DaemonAPI.DeployTargetNow],
                                 timeZone: TimeZone = .current) -> String {
        guard !targets.isEmpty else { return "\(component) in \(environment): none" }
        let parts = targets.map { t -> String in
            var words: [String] = []
            let labels = labelsLine(t.target)
            if !labels.isEmpty { words.append(labels) }
            if t.live.isEmpty { words.append(noLive) }
            for l in t.live {
                var w = "\(versionWords(l.deploy.version)) live"
                if let s = shareWords(l.share) { w += " at \(s)" }
                if let since = l.since { w += " " + sinceWords(since, timeZone: timeZone) }
                if l.deploy.rollback == true { w += ", a rollback" }
                words.append(w)
            }
            words += t.next.map(nextWords)
            return words.joined(separator: ", ")
        }
        return "\(component) in \(environment): " + parts.joined(separator: "; ")
    }
}
