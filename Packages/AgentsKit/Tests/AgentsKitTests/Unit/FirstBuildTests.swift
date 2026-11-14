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

    // MARK: The plan page (#5053, sections 3 to 6)

    @Test func anIdeaFromTheListKeepsItsStarter() {
        for idea in FirstBuild.ideas {
            #expect(FirstBuild.starter(for: idea.words) == .starter(idea.starter), "\(idea.words)")
        }
    }

    @Test func typedWordsPickByTheFirstKind() {
        #expect(FirstBuild.starter(for: "an iOS thing for my cat") == .starter(.iphoneApp))
        #expect(FirstBuild.starter(for: "Something in the App Store") == .starter(.iphoneApp))
        #expect(FirstBuild.starter(for: "an API for my recipes") == .starter(.webService))
        #expect(FirstBuild.starter(for: "a site, then an iPhone app") == .starter(.webService))
        #expect(FirstBuild.starter(for: "an app for my dog") == .unknown)
        #expect(FirstBuild.starter(for: "a game about frogs") == .neither)
        #expect(FirstBuild.starter(for: "a Mac app with a web page") == .neither)
        #expect(FirstBuild.starter(for: "web pages") == .starter(.webService))
    }

    @Test func eachListStartsWithTheAppsTwoTasks() {
        for starter in FirstBuild.Starter.allCases {
            let tasks = FirstBuild.tasks(for: starter)
            #expect(tasks.prefix(2).map(\.words) == ["Set up the agent runtime", "Connect GitHub"])
            #expect(tasks.prefix(2).allSatisfy { $0.doer == .app })
            #expect(tasks.dropFirst(2).allSatisfy { $0.doer == .agent })
        }
        #expect(FirstBuild.tasks(for: .iphoneApp).count == 8)
        #expect(FirstBuild.tasks(for: .webService).count == 7)
    }

    @Test func theAgentsTasksAreToDoUntilItsPlanComes() {
        let states = FirstBuild.states(.webService, .init(runtimeReady: true, githubConnected: false))
        #expect(states == [.done, .toDo, .toDo, .toDo, .toDo, .toDo, .toDo])
    }

    @Test func thePlanTicksTheAgentsTasksByTheirWords() {
        let plan = [
            PlanEntry(content: "Set up the agent runtime", priority: .medium, status: .completed),
            PlanEntry(content: "Connect GitHub", priority: .medium, status: .completed),
            PlanEntry(content: "Make the repository from agentloops-dev/web-service-starter", priority: .medium, status: .completed),
            PlanEntry(content: "Set up Google Cloud (Cloud Run).", priority: .medium, status: .inProgress),
            PlanEntry(content: "Set up Sentry", priority: .medium, status: .pending),
        ]
        let facts = FirstBuild.Facts(runtimeReady: true, githubConnected: true, plan: plan)
        #expect(FirstBuild.states(.webService, facts) == [.done, .done, .done, .doing, .toDo, .toDo, .toDo])
        var waiting = facts
        waiting.waitsForPerson = true
        #expect(FirstBuild.states(.webService, waiting) == [.done, .done, .done, .waitsForYou, .toDo, .toDo, .toDo])
    }

    @Test func theAgentStartsOnceTheAppsTasksAreDone() {
        #expect(!FirstBuild.canStart(.init(runtimeReady: true, githubConnected: false)))
        #expect(!FirstBuild.canStart(.init(runtimeReady: false, githubConnected: true)))
        #expect(FirstBuild.canStart(.init(runtimeReady: true, githubConnected: true)))
    }
}
