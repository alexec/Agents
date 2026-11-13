import Testing
@testable import AgentsKitCore

/// The question page's rules (#5050, `specs/5048-first-build/spec.md`, sections 1 and 2).
@Suite("First build")
struct FirstBuildTests {
    @Test func theIdeasTakeTurnsBetweenTheStarters() throws {
        try #require(FirstBuild.ideas.count == 6)
        for (index, idea) in FirstBuild.ideas.enumerated() {
            #expect(idea.starter == (index.isMultiple(of: 2) ? .iphoneApp : .webService), "\(idea.words)")
        }
    }

    @Test func thePlaceholderGoesRoundTheIdeas() throws {
        try #require(FirstBuild.ideas.count == 6)
        #expect(FirstBuild.idea(at: 0) == FirstBuild.ideas[0])
        #expect(FirstBuild.idea(at: 5) == FirstBuild.ideas[5])
        #expect(FirstBuild.idea(at: 6) == FirstBuild.ideas[0])
        #expect(FirstBuild.idea(at: -1) == FirstBuild.ideas[5])
    }

    @Test func submitSendsOnlyWords() {
        #expect(FirstBuild.submission("") == nil)
        #expect(FirstBuild.submission("  \n\t ") == nil)
        #expect(FirstBuild.submission("  An app\n") == "An app")
    }

    @Test func theHeroIsAlexs() {
        #expect(FirstBuild.hero == "Let's build your idea.")
    }
}
