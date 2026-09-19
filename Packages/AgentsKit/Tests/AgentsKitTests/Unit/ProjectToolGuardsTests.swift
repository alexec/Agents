import Foundation
import Testing
@testable import AgentsKit

/// The part of the feature where a mistake reaches somebody's work rather than their
/// window. Every rule refuses here before anything else is built on top of it.
@Suite("What a project lead may not do")
struct ProjectToolGuardsTests {
    private func agent(_ folder: String, role: AgentRole = .worker,
                       state: AgentState = .running) -> Agent {
        Agent(runtimeID: "claude", cwd: URL(filePath: folder), title: "An agent",
              state: state, endedReason: .endTurn, role: role)
    }

    @Test func aWorkerIsNotOfferedTheseAtAll() {
        let worker = agent("/work/api")
        #expect(ProjectToolGuards.check(caller: worker) == .notALead)
    }

    @Test func aLeadPasses() {
        let lead = agent("/work/api", role: .lead)
        #expect(ProjectToolGuards.check(caller: lead) == nil)
    }

    @Test func anotherProjectsAgentIsRefused() {
        let lead = agent("/work/api", role: .lead)
        let elsewhere = agent("/side/web")
        #expect(ProjectToolGuards.check(caller: lead, target: elsewhere, projectName: "api")
                == .otherProject(projectName: "api"))
    }

    @Test func itsOwnProjectsAgentIsAllowed() {
        let lead = agent("/work/api", role: .lead)
        let worker = agent("/work/api")
        #expect(ProjectToolGuards.check(caller: lead, target: worker, projectName: "api") == nil)
    }

    @Test func aNestedFolderIsAnotherProject() {
        // Projects are matched by exact folder. A lead in `api` has no reach into
        // `api/docs`, which is a project of its own with a lead of its own.
        let lead = agent("/work/api", role: .lead)
        let nested = agent("/work/api/docs")
        #expect(ProjectToolGuards.check(caller: lead, target: nested, projectName: "api") != nil)
    }

    @Test func aLeadCannotStopItself() {
        let lead = agent("/work/api", role: .lead)
        #expect(ProjectToolGuards.checkStop(caller: lead, target: lead, projectName: "api")
                == .itself)
    }

    @Test func stoppingSomethingAlreadyDoneIsNothingToDo() {
        let lead = agent("/work/api", role: .lead)
        let done = agent("/work/api", state: .finished)
        #expect(ProjectToolGuards.checkStop(caller: lead, target: done, projectName: "api")
                == .alreadySettled)
    }

    @Test func stoppingSomethingLiveIsAllowed() {
        let lead = agent("/work/api", role: .lead)
        let working = agent("/work/api", state: .running)
        #expect(ProjectToolGuards.checkStop(caller: lead, target: working, projectName: "api") == nil)
    }

    @Test func anArchivedAgentIsNotGivenWork() {
        let lead = agent("/work/api", role: .lead)
        let archived = agent("/work/api", state: .archived)
        #expect(ProjectToolGuards.checkPrompt(caller: lead, target: archived, projectName: "api")
                == .archived)
    }

    @Test func aWorkerCannotReachAnythingEvenInItsOwnProject() {
        let worker = agent("/work/api")
        let other = agent("/work/api")
        #expect(ProjectToolGuards.checkStop(caller: worker, target: other, projectName: "api")
                == .notALead)
    }

    @Test func aToolOnlyEverCreatesWorkers() {
        // There is no argument for this and no other path to `.lead`: a lead is made
        // with its project or not at all.
        #expect(ProjectToolGuards.roleForStartedAgents == .worker)
    }

    @Test func everyRefusalIsASentenceTheLeadCanAct0n() {
        let refusals: [ProjectToolGuards.Refusal] = [
            .notALead, .otherProject(projectName: "api"), .itself, .alreadySettled, .archived,
        ]
        for refusal in refusals {
            let message = refusal.message(projectName: "api")
            #expect(!message.isEmpty)
            #expect(message.hasSuffix("."), "a sentence, not a code")
        }
    }
}
