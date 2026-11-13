import Foundation

/// The first build (#5048): a newcomer's first open asks one question, **Let's build your
/// idea.**, and an agent builds the idea from a starter (`specs/5048-first-build/spec.md`).
public enum FirstBuild {
    /// The two kinds of app a first build starts from: the templates `make_app_repository`
    /// makes a repository from.
    public enum Starter: String, Codable, CaseIterable, Sendable {
        case iphoneApp = "iphone-app"
        case webService = "web-service"
    }

    /// An idea the question page offers in its placeholder, and the starter it takes.
    public struct Idea: Codable, Equatable, Sendable {
        public var words: String
        public var starter: Starter

        public init(_ words: String, _ starter: Starter) {
            self.words = words
            self.starter = starter
        }
    }

    /// The question page's hero text (Alex, 2026-11-12).
    public static let hero = "Let's build your idea."

    /// The ideas, half for each starter, in turn (spec, section 2). The web page has the same
    /// list in the same order: `Fixtures/web/first-build/ideas.json` holds both to it.
    public static let ideas: [Idea] = [
        Idea("An iPhone app that shows the weather where I am", .iphoneApp),
        Idea("A web page that shows this week's weather for my town", .webService),
        Idea("An iPhone app that reminds me to water my plants", .iphoneApp),
        Idea("A website for my book club's reading list", .webService),
        Idea("An iPhone app that logs my runs", .iphoneApp),
        Idea("A web service that emails me a daily summary of my GitHub", .webService),
    ]

    /// How long each idea shows in the placeholder before the next one.
    public static let ideaSeconds: Double = 4

    /// The idea the placeholder shows at `tick`, the count of changes since it started.
    public static func idea(at tick: Int) -> Idea {
        ideas[((tick % ideas.count) + ideas.count) % ideas.count]
    }

    /// The words Submit sends: trimmed, or nil while there is nothing to send.
    public static func submission(_ text: String) -> String? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }
}

// MARK: - The plan page (#5053, spec sections 3 to 6)

extension FirstBuild {
    /// What the words of an idea say about its starter (section 3 and 4).
    public enum Pick: Codable, Equatable, Sendable {
        /// The words name one of the two starters.
        case starter(Starter)
        /// The words name no kind of app: the plan page asks.
        case unknown
        /// The words name a kind the starters do not make (a Mac app, a game): the plan page
        /// says what it can build, and asks.
        case neither
    }

    /// The words that pick `iphone-app`, `web-service`, or neither of the two.
    static let iphoneWords: Set<String> = ["iphone", "ios", "ipad", "testflight"]
    static let webWords: Set<String> = ["web", "website", "site", "page", "service", "server", "api", "email"]
    static let neitherWords: Set<String> = ["mac", "macos", "android", "game", "windows", "desktop"]

    /// The starter an idea picks: an idea from the list keeps its own; typed words pick by
    /// the first word that names a kind (`app store` names the iPhone app). A bare "app"
    /// picks nothing. The web page's `firstBuildStarter` is held to the same fixture.
    public static func starter(for idea: String) -> Pick {
        let trimmed = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        if let listed = ideas.first(where: { $0.words.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return .starter(listed.starter)
        }
        let words = trimmed.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        for (index, word) in words.enumerated() {
            if iphoneWords.contains(word) { return .starter(.iphoneApp) }
            if word == "app", index + 1 < words.count, words[index + 1] == "store" { return .starter(.iphoneApp) }
            if webWords.contains(word) { return .starter(.webService) }
            if neitherWords.contains(word) { return .neither }
        }
        return .unknown
    }

    /// The line under an unfit idea's title (section 4).
    public static let neitherLine =
        "Agents can start with an iPhone app or a web service. Choose one, and the agent builds your idea on it as far as it goes."

    /// Who does a task: the app, before the agent can start, or the agent.
    public enum Doer: String, Codable, Sendable {
        case app
        case agent
    }

    /// One task of a starter's list, in the skill's exact words (section 6).
    public struct PlanTask: Codable, Equatable, Sendable, Identifiable {
        public var words: String
        public var doer: Doer
        public var id: String { words }

        public init(_ words: String, _ doer: Doer) {
            self.words = words
            self.doer = doer
        }
    }

    /// The app's two tasks, first on both lists.
    public static let runtimeTask = "Set up the agent runtime"
    public static let githubTask = "Connect GitHub"

    /// A starter's task list, in order. The skill writes the same words as its plan
    /// (`start-a-new-app`, #5052).
    public static func tasks(for starter: Starter) -> [PlanTask] {
        let app = [PlanTask(runtimeTask, .app), PlanTask(githubTask, .app)]
        switch starter {
        case .iphoneApp:
            return app + [
                PlanTask("Make the repository from alexec/iphone-app-starter", .agent),
                PlanTask("Join the Apple Developer Program", .agent),
                PlanTask("Put the App Store Connect key in the repository's CI", .agent),
                PlanTask("Set up Sentry", .agent),
                PlanTask("Send the first build to TestFlight", .agent),
                PlanTask("Approve the first build", .agent),
            ]
        case .webService:
            return app + [
                PlanTask("Make the repository from alexec/web-service-starter", .agent),
                PlanTask("Set up Google Cloud (Cloud Run)", .agent),
                PlanTask("Set up Sentry", .agent),
                PlanTask("Deploy the first version", .agent),
                PlanTask("Approve the first deploy", .agent),
            ]
        }
    }

    /// The line under the title: what will be built, and from which template.
    public static func starterLine(_ starter: Starter) -> String {
        switch starter {
        case .iphoneApp: "An iPhone app, from alexec/iphone-app-starter"
        case .webService: "A web service, from alexec/web-service-starter"
        }
    }

    /// The choice's own words, on the plan page's control.
    public static func kindName(_ starter: Starter) -> String {
        switch starter {
        case .iphoneApp: "iPhone app"
        case .webService: "Web service"
        }
    }

    /// A task's state on the plan page.
    public enum TaskState: String, Codable, Sendable {
        case toDo = "to-do"
        case doing
        case done
        /// The agent's task whose step waits on a card for the person.
        case waitsForYou = "waits-for-you"
    }

    /// What the plan page knows (section 6): the app's two tasks from real state, the agent's
    /// from its plan, matched by words.
    public struct Facts: Codable, Equatable, Sendable {
        public var runtimeReady: Bool
        public var githubConnected: Bool
        /// The plan in force of the first-build session, when it has sent one.
        public var plan: [PlanEntry]?
        /// The session waits on the person (a card, a question).
        public var waitsForPerson: Bool

        public init(runtimeReady: Bool, githubConnected: Bool, plan: [PlanEntry]? = nil, waitsForPerson: Bool = false) {
            self.runtimeReady = runtimeReady
            self.githubConnected = githubConnected
            self.plan = plan
            self.waitsForPerson = waitsForPerson
        }
    }

    /// Each task of the starter with its state. The agent's tasks are to do until its plan
    /// comes; a task the plan does not name stays to do. The task in progress shows
    /// **waits for you** while the session waits on the person.
    public static func states(_ starter: Starter, _ facts: Facts) -> [TaskState] {
        tasks(for: starter).map { task in
            switch task.words {
            case runtimeTask: return facts.runtimeReady ? .done : .toDo
            case githubTask: return facts.githubConnected ? .done : .toDo
            default: break
            }
            let entry = facts.plan?.first { normalised($0.content) == normalised(task.words) }
            switch entry?.status {
            case .completed: return .done
            case .inProgress: return facts.waitsForPerson ? .waitsForYou : .doing
            case .pending, nil: return .toDo
            }
        }
    }

    /// Whether the app's tasks are done, so the agent can start.
    public static func canStart(_ facts: Facts) -> Bool { facts.runtimeReady && facts.githubConnected }

    private static func normalised(_ words: String) -> String {
        words.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "."))).lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// The label `firstBuild/start` gives the session, by which the plan page finds it.
    public static let label = "first-build"
}

extension Agent {
    /// The first-build session (#5053): labelled `first-build`, and not archived.
    public var isFirstBuild: Bool {
        state != .archived && archivedAt == nil && labels.contains { $0.value == FirstBuild.label }
    }
}
