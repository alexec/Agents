import Foundation
import Testing
@testable import AgentsKitCore

/// The one list of what can happen (042 FR-003, FR-022, FR-024).
@Suite("The event catalogue")
struct EventCatalogueTests {
    @Test func thereAreThirtyOneUniqueWellFormedNames() {
        let names = EventCatalogue.all.map(\.name)
        // 30 from 042, 051's agent.retired (agent.deleted since #398), and 052's switch and two allowance kinds,
        // less the ten pull-request kinds that went with GitHub support, and the switch,
        // which went with the pool (065), and agent.parked (agent.archive_requested since #584)
        // and agent.archived (#96), and
        // mac.disk_low and mac.disk_ok (#195, machine.* since #372), folder.idle (#360),
        // and dropbox.file_added (#231), and agent.messaged (#560), and system.restarted (#1219).
        #expect(names.count == 31)
        for name in ["system.restarted", "cost.allowance_out", "cost.allowance_back", "agent.archive_requested", "agent.archived",
                     "machine.disk_low", "machine.disk_ok", "folder.idle", "dropbox.file_added",
                     "agent.messaged", "agent.waiting"] {
            #expect(names.contains(name), "\(name)")
        }
        #expect(!names.contains("agent.runtime_switched"))
        #expect(!names.contains("agent.blocked"))
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
        #expect(EventList.text().contains(#""name":"mac.wake","source":"app","description":"This Mac woke up. Only a Mac raises it"#))
    }

    /// The names from before events and renames (#575) are unknown, and each is refused
    /// with the event to use, where the suggestion can find one.
    @Test func oldNamesAreRefusedWithTheEventToUse() {
        let expected = ["agent-finished": "agent.finished", "agent-asked-permission": "agent.asked_permission",
                        "agent-asked-form": "agent.asked_form", "agent-stopped": "agent.stopped",
                        "workflow-completed": "workflow.completed", "mac.disk_low": "machine.disk_low",
                        "mac.disk_ok": "machine.disk_ok"]
        for (old, now) in expected {
            #expect(EventCatalogue.kind(named: old) == nil, "\(old)")
            guard case .failure(let problem) = EventPattern.parse(old) else {
                Issue.record("\(old) was read as an event")
                continue
            }
            #expect(problem.message.contains("Did you mean \(now)?"), "\(old)")
        }
        for old in ["agent.retired", "agent.parked"] {
            guard case .failure = EventPattern.parse(old) else {
                Issue.record("\(old) was read as an event")
                continue
            }
        }
    }

    @Test func theDescriptionNamesEveryKindAndNoCustomFamily() {
        let text = EventList.text()
        for kind in EventCatalogue.all { #expect(text.contains(kind.name)) }
        #expect(!text.contains("custom."))
        #expect(text.contains("agent.*"))
    }

    @Test func everyAgentEventCarriesTheAgentsContext() throws {
        for kind in EventCatalogue.kinds(in: .agent) + [EventCatalogue.kind(named: "cost.limit_reached")!] {
            for key in ["labels", "runtime", "started_by"] { #expect(kind.details.contains(key), "\(kind.name) \(key)") }
        }
        #expect(EventCatalogue.kind(named: "agent.finished")!.details.contains("afterwards"))
        for name in ["agent.archive_requested", "agent.archived", "workflow.completed"] {
            #expect(EventCatalogue.kind(named: name)!.details.contains("outcome"), "\(name)")
        }
        let finished = try #require(EventCatalogue.kind(named: "agent.finished"))
        let granted = try #require(EventCatalogue.kind(named: "lease.granted"))
        #expect(finished.filters.isEmpty)
        #expect(granted.details == ["resource", "agent"])
    }

    /// Only four events take a filter (#574, #2361), and only those have an inputSchema
    /// with anything in it (#579).
    @Test func onlyTheFiltersAreInTheInputSchema() throws {
        let filtered = EventCatalogue.all.filter { !$0.filters.isEmpty }
            .map { "\($0.name) \($0.filters.map(\.key).joined(separator: ","))" }
        #expect(filtered == ["branch.moved branch", "lease.granted resource,agent", "person.away why", "person.back why"])
        let branch = try #require(EventCatalogue.kind(named: "branch.moved"))
        #expect(branch.inputSchema == ["type": "object", "additionalProperties": false,
                                       "properties": ["branch": ["type": "string"]]])
        let away = try #require(EventCatalogue.kind(named: "person.away"))
        #expect(away.inputSchema["properties"]?["why"] == ["type": "string", "enum": ["locked", "idle"]])
        let finished = try #require(EventCatalogue.kind(named: "agent.finished"))
        #expect(finished.inputSchema == ["type": "object", "additionalProperties": false, "properties": [:]])
        #expect(EventList.text().contains("use wait_for_agents"))
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
        #expect(values("agent.finished", "afterwards") == ["archive_requested", "archived", "stay"])
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
        #expect(entries.count == EventCatalogue.all.count + 1)
        let app = entries.prefix(EventCatalogue.all.count)
        #expect(app.allSatisfy { $0?["source"] == "app" })
        #expect(app.compactMap { $0?["name"]?.stringValue } == EventCatalogue.all.map(\.name))
        let last = try #require(entries.last ?? nil)
        #expect(last["source"] == "github")
        #expect(last["name"] == "pr.merged")
        #expect(last["inputSchema"] == server.inputSchema)
        #expect(last["payloadSchema"] == server.payloadSchema)
        #expect(text.contains("Not listed: Can't reach ci"))
    }

    /// Agents no longer publish (#639): every `custom.` name, and the subject, is the
    /// retired family, and none of it can pass for a server's event either.
    @Test func customNamesAreRetired() {
        for name in ["custom.build_green", "custom.v2", "custom.*", "custom.Build"] {
            #expect(EventCatalogue.isRetiredCustom(name), "\(name)")
            #expect(!EventCatalogue.isServerEventName(name), "\(name)")
        }
        #expect(!EventCatalogue.isRetiredCustom("mac.wake"))
        #expect(!EventCatalogue.isRetiredCustom("customer.signed_up"))
        #expect(EventCatalogue.isServerEventName("customer.signed_up"))
        #expect(EventSubject(name: "custom.build_green") == nil)
    }

    @Test func everySubjectHasAGroupAndTheGroupsCoverThemAll() {
        let grouped = EventGroup.allCases.flatMap(\.subjects)
        #expect(Set(grouped) == Set(EventSubject.allCases))
        #expect(EventGroup.mac.subjects.contains(.person))
    }

    /// A kind nothing raises is a wait that never ends and a workflow that never runs:
    /// every name in the catalogue is written somewhere in the hosts' sources, which are Go
    /// since #1314: `Go/`, less its tests and the wire's own copy of the catalogue.
    @Test func everyKindIsRaisedSomewhere() throws {
        let go = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Go")
        var text = ""
        let files = FileManager.default.enumerator(at: go, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "go", !file.lastPathComponent.hasSuffix("_test.go"),
                  !file.path.contains("/Go/wire/") else { continue }
            text += try String(contentsOf: file, encoding: .utf8)
        }
        #expect(!text.isEmpty)
        // Not raised by the Go host yet (#1368): take each off as it is.
        let notYet: Set<String> = ["mac.sleep", "mac.wake", "person.away", "person.back", "folder.idle"]
        for kind in EventCatalogue.all where !notYet.contains(kind.name) {
            #expect(text.contains("\"\(kind.name)\""), "nothing raises \(kind.name)")
        }
    }
}
