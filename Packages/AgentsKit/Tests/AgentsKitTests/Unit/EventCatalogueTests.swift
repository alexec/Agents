import Foundation
import Testing
@testable import AgentsKitCore

/// The one list of what can happen (042 FR-003, FR-022, FR-024).
@Suite("The event catalogue")
struct EventCatalogueTests {
    @Test func thereAreTwentyEightUniqueWellFormedNames() {
        let names = EventCatalogue.all.map(\.name)
        // 30 from 042, 051's agent.retired, and 052's switch and two allowance kinds,
        // less the ten pull-request kinds that went with GitHub support, and the switch,
        // which went with the pool (065), and agent.parked and agent.archived (#96), and
        // mac.disk_low and mac.disk_ok (#195, machine.* since #372), and project.idle (#360).
        #expect(names.count == 28)
        for name in ["cost.allowance_out", "cost.allowance_back", "agent.parked", "agent.archived",
                     "machine.disk_low", "machine.disk_ok", "project.idle"] {
            #expect(names.contains(name), "\(name)")
        }
        #expect(!names.contains("agent.runtime_switched"))
        #expect(Set(names).count == names.count)
        for name in names { #expect(EventDraft.isWellFormed(name), "\(name)") }
        for kind in EventCatalogue.all { #expect(EventSubject(name: kind.name) != nil, "\(kind.name)") }
    }

    /// What a Linux server never raises (#372).
    @Test func sleepWakeAndThePersonAreMacOnly() {
        let macOnly = EventCatalogue.all.filter(\.isMacOnly).map(\.name)
        #expect(macOnly == ["mac.sleep", "mac.wake", "person.away", "person.back"])
        #expect(EventCatalogue.isMacOnly("person.*"))
        #expect(EventCatalogue.isMacOnly("mac.*"))
        #expect(!EventCatalogue.isMacOnly("machine.*"))
        #expect(!EventCatalogue.isMacOnly("machine.disk_low"))
        #expect(!EventCatalogue.isMacOnly("custom.mac_wake"))
        #expect(EventCatalogue.describe().contains("- mac.wake: This Mac woke up. Only a Mac raises it"))
    }

    @Test func everyOldTriggerNameAnswersToAKind() {
        let old = ["agent-finished", "agent-asked-permission", "agent-asked-form", "agent-stopped",
                   "workflow-completed"]
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
        #expect(text.contains("agent.*"))
    }

    @Test func everyAgentEventCarriesTheAgentsContext() throws {
        for kind in EventCatalogue.kinds(in: .agent) + [EventCatalogue.kind(named: "cost.limit_reached")!] {
            for key in ["labels", "runtime", "started_by"] { #expect(kind.details.contains(key), "\(kind.name) \(key)") }
        }
        #expect(EventCatalogue.kind(named: "agent.finished")!.details.contains("afterwards"))
        for name in ["agent.parked", "agent.archived", "workflow.completed"] {
            #expect(EventCatalogue.kind(named: name)!.details.contains("outcome"), "\(name)")
        }
        let finished = try #require(EventCatalogue.kind(named: "agent.finished"))
        let granted = try #require(EventCatalogue.kind(named: "lease.granted"))
        #expect(finished.detail("labels")?.isSet == true)
        #expect(granted.details == ["resource", "agent"])
    }

    @Test func theDescriptionListsFixedValuesAndTheContextOnce() {
        let text = EventCatalogue.describe()
        #expect(text.contains("- agent.finished [agent, outcome=done|nothing_to_do|needs_answer|partly_done|stuck|blocked, "
                              + "afterwards=park|stay, …]"))
        #expect(text.contains("Every agent event also carries labels"))
        #expect(text.contains("started_by=person|workflow|agent"))
        #expect(text.contains("outcome: [done, nothing_to_do]"))
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
