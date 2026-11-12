import Foundation
import Testing
@testable import AgentsKitCore

/// Undo (⌘Z) for every optimistic action that has an inverse (#4793): what Undo sends, and
/// that nothing is offered for an action that changed nothing.
@Suite("Session undo")
struct SessionUndoTests {
    private func agent(title: String = "Fix the parser", state: AgentState = .finished) -> Agent {
        Agent(id: UUID(), runtimeID: "claude", cwd: URL(filePath: "/tmp/work/api"), title: title, state: state,
              lastActivityAt: Date())
    }

    @Test func unarchiveIsUndoneByArchive() throws {
        let held = agent(state: .archived)
        let undo = try #require(SessionUndo.unarchived(held))
        #expect(undo.inverse == .archive(held.id))
        #expect(undo.line == "Unarchived “Fix the parser”")
        #expect(undo.menuTitle == "Undo Unarchive")
        #expect(SessionUndo.unarchived(agent(state: .finished)) == nil)
    }

    @Test func renameGivesTheRuntimesTitleBack() throws {
        let held = agent()
        let undo = try #require(SessionUndo.renamed(held, to: "Parser"))
        // The runtime named it, so Undo is an empty title: the runtime's again.
        #expect(undo.inverse == .rename(held.id, to: ""))
        #expect(undo.line == "Renamed “Fix the parser” to “Parser”")
    }

    @Test func renameGivesThePersonsTitleBack() throws {
        var held = agent(title: "Mine")
        held.titleIsPersons = true
        let undo = try #require(SessionUndo.renamed(held, to: ""))
        #expect(undo.inverse == .rename(held.id, to: "Mine"))
        #expect(undo.line == "Gave “Mine” its runtime’s title")
        #expect(SessionUndo.renamed(held, to: " Mine ") == nil)
    }

    @Test func labelsUndoOnlyWhatChanged() throws {
        var held = agent()
        held.labels = [SessionLabel(value: "bug", owner: .person)]
        let undo = try #require(SessionUndo.labels(held, add: ["bug", "ui"], remove: ["Bug"]))
        // "bug" was there already, so Undo puts it back and does not take it away.
        #expect(undo.inverse == .labels(held.id, add: ["bug"], remove: ["ui"]))
        #expect(undo.line == "Changed the labels of “Fix the parser”")
        #expect(SessionUndo.labels(held, add: ["bug"], remove: []) == nil)
    }

    @Test func muteIsSetBack() throws {
        let held = agent()
        let undo = try #require(SessionUndo.muted(held, true))
        #expect(undo.inverse == .mute(held.id, false))
        #expect(undo.menuTitle == "Undo Mute")
        #expect(SessionUndo.muted(held, false) == nil)
    }

    @Test func theAnnouncementEndsWithUndo() throws {
        let undo = try #require(SessionUndo.muted(agent(), true))
        #expect(undo.announcement == "Muted “Fix the parser”. Undo")
    }
}
