import Foundation
import Testing
@testable import AgentsKitCore

/// Start a Machine from a Repository (#1809), as the web page's machineFromRepository.test.mjs.
@Suite("Machine from a repository")
struct MachineFromRepositoryTests {
    typealias M = MachineFromRepository

    @Test func aRepositoryIsAnHTTPSAddressWithAnOwnerAndAName() {
        #expect(M.repository(" https://github.com/alexec/agents.git ")
            == M.Repository(url: "https://github.com/alexec/agents.git", path: "alexec/agents", name: "agents"))
        #expect(M.repository("https://gitlab.com/group/sub/proj")?.path == "group/sub/proj")
        for bad in ["git@github.com:alexec/agents.git", "http://github.com/a/b", "https://github.com/agents",
                    "https://token@github.com/a/b", "https://github.com/a/b?x=1", ""] {
            #expect(M.repository(bad) == nil, "\(bad)")
        }
    }

    @Test func theMachinesNameIsTheRepositorysAsAHostName() {
        #expect(M.machineName("Agents", suffix: "0a1f") == "agents-0a1f")
        #expect(M.machineName("my_repo.js", suffix: "beef") == "my-repo-js-beef")
        #expect(M.machineName("2048", suffix: "0001") == "m-2048-0001")
        #expect(M.machineName(String(repeating: "a", count: 40), suffix: "0001") == String(repeating: "a", count: 30) + "-0001")
        #expect(M.nameSuffix().count == 4)
    }

    @Test func theFormLeavesOutRepositoryAndTheRequestTypesItsValues() throws {
        let schema = try JSONValue.parse(Data("""
            {"type": "object", "properties": {"repository": {"type": "string"},
             "region": {"type": "string", "title": "Region", "default": "nyc3"},
             "size": {"type": "string", "enum": ["small", "big"], "default": "small"},
             "disk": {"type": "integer", "title": "Disk", "default": 20}, "spot": {"type": "boolean", "default": false}}}
            """.utf8))
        let fields = M.fields(schema)
        try #require(fields.map(\.key) == ["disk", "region", "size", "spot"])
        #expect(fields.map(\.value) == ["20", "nyc3", "small", "false"])
        #expect(fields[2].choices == ["small", "big"])
        let repository = try #require(M.repository("https://github.com/alexec/agents"))
        let request = M.request(ProviderID(rawValue: "do"), name: "agents-0a1f", repository: repository, fields: fields)
        #expect(request.repository == "https://github.com/alexec/agents")
        #expect(request.options == .object(["region": "nyc3", "size": "small", "disk": .int(20), "spot": .bool(false)]))
    }
}
