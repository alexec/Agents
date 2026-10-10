import Foundation
import Testing
@testable import AgentsKitCore

/// The one list of what can happen (042 FR-003, FR-022, FR-024).
@Suite("The event catalogue")
struct EventCatalogueTests {
    @Test func thereAreThirtyUniqueWellFormedNames() {
        let names = EventCatalogue.all.map(\.name)
        // 30 from 042, 051's agent.retired (agent.deleted since #398), and 052's switch and two allowance kinds,
        // less the ten pull-request kinds that went with GitHub support, and the switch,
        // which went with the pool (065), and agent.parked and agent.archived (#96), and
        // mac.disk_low and mac.disk_ok (#195, machine.* since #372), project.idle (#360),
        // and dropbox.file_added (#231), and agent.messaged (#560).
        #expect(names.count == 30)
        for name in ["cost.allowance_out", "cost.allowance_back", "agent.parked", "agent.archived",
                     "machine.disk_low", "machine.disk_ok", "project.idle", "dropbox.file_added",
                     "agent.messaged"] {
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
        #expect(EventList.text().contains(#""name":"mac.wake","source":"app","description":"This Mac woke up. Only a Mac raises it"#))
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
        let text = EventList.text()
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
        #expect(finished.filters.isEmpty)
        #expect(granted.details == ["resource", "agent"])
    }

    /// Only three events take a filter (#574), and only those have an inputSchema
    /// with anything in it (#579).
    @Test func onlyTheFiltersAreInTheInputSchema() throws {
        let filtered = EventCatalogue.all.filter { !$0.filters.isEmpty }
            .map { "\($0.name) \($0.filters.map(\.key).joined(separator: ","))" }
        #expect(filtered == ["branch.moved branch", "person.away why", "person.back why"])
        let branch = try #require(EventCatalogue.kind(named: "branch.moved"))
        #expect(branch.inputSchema == ["type": "object", "additionalProperties": false,
                                       "properties": ["branch": ["type": "string"]]])
        let away = try #require(EventCatalogue.kind(named: "person.away"))
        #expect(away.inputSchema["properties"]?["why"] == ["type": "string", "enum": ["locked", "idle"]])
        let finished = try #require(EventCatalogue.kind(named: "agent.finished"))
        #expect(finished.inputSchema == ["type": "object", "additionalProperties": false, "properties": [:]])
        #expect(EventList.text().contains("use wait_for_event with agents"))
    }

    // MARK: #579: the app's events in events/list's shape

    /// Every kind's two schemas are objects the checker can read: every detail in the
    /// payload, every filter in the input, and fixed values as an enum.
    @Test func everyKindProducesAValidSchema() throws {
        for kind in EventCatalogue.all {
            let input = kind.inputSchema, payload = kind.payloadSchema
            #expect(input["type"] == "object", "\(kind.name)")
            #expect(input["additionalProperties"] == false, "\(kind.name)")
            #expect(Set(input["properties"]?.objectValue?.keys ?? [:].keys) == Set(kind.filters.map(\.key)), "\(kind.name)")
            #expect(payload["type"] == "object", "\(kind.name)")
            let shown = try #require(payload["properties"]?.objectValue, "\(kind.name)")
            for detail in kind.detailDescriptions {
                #expect(shown[detail.key]?["type"] == "string", "\(kind.name) \(detail.key)")
                if let values = detail.values {
                    #expect(shown[detail.key]?["enum"] == .array(values.map(JSONValue.string)), "\(kind.name) \(detail.key)")
                }
            }
            if kind.details.contains("agent") { #expect(shown["agent_title"] != nil, "\(kind.name)") }
            // Nothing the kind does not take passes, and nothing it does take is refused.
            #expect(JSONSchemaSubset.check(["nope": "x"], against: input, name: kind.name) != nil, "\(kind.name)")
            #expect(JSONSchemaSubset.check([:], against: input, name: kind.name) == nil, "\(kind.name)")
            let definition = kind.definition
            #expect(definition.name == kind.name)
            #expect(definition.description?.hasPrefix(kind.meaning) == true)
        }
    }

    @Test func fixedValuesAreThePayloadsEnums() throws {
        func values(_ name: String, _ key: String) -> [String]? {
            EventCatalogue.kind(named: name)?.payloadSchema["properties"]?[key]?["enum"]?.arrayValue?.compactMap(\.stringValue)
        }
        #expect(values("agent.finished", "outcome") == WorkOutcome.allCases.map(\.rawValue))
        #expect(values("agent.finished", "afterwards") == ["park", "stay"])
        #expect(values("agent.failed", "reason") == EndedReason.allCases.map(\.code))
        #expect(values("workflow.refused", "reason") == WorkflowRefusal.codes)
        #expect(values("machine.disk_low", "level") == ["low", "critical"])
        #expect(values("lease.released", "how") == ["expired", "ended", "released"])
        #expect(values("agent.started", "started_by") == ["agent", "workflow", "person"])
        #expect(values("branch.moved", "branch") == nil)
    }

    /// The list is the app's events then each server's, each a line of JSON with its
    /// source, and a custom event's payload open.
    @Test func theListHasBothKindsWithTheirSource() throws {
        let server = EventDefinition(name: "pr.merged", description: "A pull request merged.",
                                     inputSchema: ["type": "object", "properties": ["repo": ["type": "string"]]],
                                     payloadSchema: ["type": "object", "properties": ["number": ["type": "integer"]]])
        let text = EventList.text(servers: [(source: "github", events: [server])],
                                  unlisted: ["Not listed: Can't reach ci: it stopped."])
        let entries = text.split(separator: "\n").filter { $0.hasPrefix("{") }.map { line in
            try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        }
        #expect(entries.count == EventCatalogue.all.count + 2)
        let app = entries.prefix(EventCatalogue.all.count + 1)
        #expect(app.allSatisfy { $0?["source"] == "app" })
        #expect(app.compactMap { $0?["name"]?.stringValue } == EventCatalogue.all.map(\.name) + ["custom.<name>"])
        #expect(app.last??["payloadSchema"] == ["type": "object"])
        let last = try #require(entries.last ?? nil)
        #expect(last["source"] == "github")
        #expect(last["name"] == "pr.merged")
        #expect(last["inputSchema"] == server.inputSchema)
        #expect(last["payloadSchema"] == server.payloadSchema)
        #expect(text.contains("Not listed: Can't reach ci"))
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
