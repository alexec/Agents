import Foundation
import Testing
@testable import AgentsKitCore

/// The one list of what can happen (042 FR-003, FR-022, FR-024).
@Suite("The event catalogue")
struct EventCatalogueTests {
    @Test func thereAreThirtyUniqueWellFormedNames() {
        let names = EventCatalogue.all.map(\.name)
        #expect(names.count == 30)
        #expect(Set(names).count == names.count)
        for name in names { #expect(EventDraft.isWellFormed(name), "\(name)") }
        for kind in EventCatalogue.all { #expect(EventSubject(name: kind.name) != nil, "\(kind.name)") }
    }

    @Test func everyOldTriggerNameAnswersToAKind() {
        let old = ["agent-finished", "agent-asked-permission", "agent-asked-form", "agent-stopped",
                   "workflow-completed", "pull-request-checks-failed", "pull-request-review-comments",
                   "pull-request-conflicts"]
        for alias in old { #expect(!EventCatalogue.kinds(forAlias: alias).isEmpty, "\(alias)") }
        #expect(EventCatalogue.kinds(forAlias: "schedule").isEmpty)
    }

    @Test func agentStoppedCoversStoppedAndFailed() {
        #expect(Set(EventCatalogue.kinds(forAlias: "agent-stopped").map(\.name))
                == ["agent.stopped", "agent.failed"])
    }

    @Test func theDescriptionNamesEveryKindAndTheCustomFamily() {
        let text = EventCatalogue.describe()
        for kind in EventCatalogue.all { #expect(text.contains(kind.name)) }
        #expect(text.contains("custom.<name>"))
        #expect(text.contains("pull_request.*"))
    }

    @Test func customNamesAreLowercaseAndShort() {
        #expect(EventCatalogue.isCustom("custom.build_green"))
        #expect(EventCatalogue.isCustom("custom.v2"))
        #expect(!EventCatalogue.isCustom("custom."))
        #expect(!EventCatalogue.isCustom("custom.Build"))
        #expect(!EventCatalogue.isCustom("custom." + String(repeating: "a", count: 41)))
        #expect(!EventCatalogue.isCustom("mac.wake"))
    }

    @Test func everySubjectHasAGroupAndTheGroupsCoverThemAll() {
        let grouped = EventGroup.allCases.flatMap(\.subjects)
        #expect(Set(grouped) == Set(EventSubject.allCases))
        #expect(EventGroup.mac.subjects.contains(.person))
    }

    /// A kind nothing raises is a wait that never ends and a workflow that never runs:
    /// every name in the catalogue is written somewhere in the sources besides the
    /// catalogue itself, which is where its events are raised.
    @Test func everyKindIsRaisedSomewhere() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources")
        var text = ""
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", file.lastPathComponent != "EventCatalogue.swift" else { continue }
            text += try String(contentsOf: file, encoding: .utf8)
        }
        #expect(!text.isEmpty)
        for kind in EventCatalogue.all {
            #expect(text.contains("\"\(kind.name)\""), "nothing raises \(kind.name)")
        }
    }
}
