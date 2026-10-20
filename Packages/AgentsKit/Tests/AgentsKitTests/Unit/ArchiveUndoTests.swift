import Foundation
import Testing
@testable import AgentsKitCore

/// One Undo for a ⌫ over a selection (#1664): the strip counts what it put away.
@Suite("Archive undo")
struct ArchiveUndoTests {
    @Test func oneSessionIsNamed() {
        let undo = ArchiveUndo(agentIDs: [UUID(), UUID()], title: "Fix the parser", stopped: false)
        #expect(undo.line == "Archived “Fix the parser”")
    }

    @Test func aSelectionIsCounted() {
        let undo = ArchiveUndo(agentIDs: [UUID(), UUID(), UUID()], title: "Fix the parser",
                               stopped: false, sessions: 3)
        #expect(undo.line == "Archived 3 sessions")
    }

    @Test func workflowsAreCountedToo() {
        #expect(ArchiveUndo.line(sessions: 2, workflows: 1, stopped: false) == "Archived 2 sessions and 1 workflow")
        #expect(ArchiveUndo.line(sessions: 0, workflows: 2, stopped: false) == "Archived 2 workflows")
    }

    @Test func aStoppedOneIsSaid() {
        #expect(ArchiveUndo.line(sessions: 3, workflows: 0, stopped: true)
            == "Archived 3 sessions. Undo does not start the stopped ones again.")
    }

    /// VoiceOver is told that Undo is there (#1676).
    @Test func theAnnouncementEndsWithUndo() {
        #expect(ArchiveUndo(agentIDs: [], title: "Fix the parser", stopped: false).announcement
            == "Archived “Fix the parser”. Undo")
        #expect(ArchiveUndo(agentIDs: [], title: "Fix the parser", stopped: true).announcement
            == "Archived “Fix the parser” and stopped it. Undo does not start it again. Undo")
    }
}
