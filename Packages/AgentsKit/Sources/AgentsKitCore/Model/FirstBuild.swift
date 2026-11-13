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
