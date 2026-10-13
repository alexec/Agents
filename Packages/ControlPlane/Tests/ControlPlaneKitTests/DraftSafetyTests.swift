import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

// What a draft's check may run without asking (#858, FR-013, FR-014), and what its agent
// never sees (FR-022).

@Suite("A draft's check: run or ask (#858)")
struct DraftSafetyTests {
    static func map(_ list: String, arguments: JSONValue? = nil, start: String = "power-on", stop: String = "power-off") -> JSONValue {
        var call: [String: JSONValue] = ["tool": .string(list), "items": "", "id": "id", "name": "name", "state": "state"]
        if let arguments { call["arguments"] = arguments }
        return ["list": .object(call), "start": ["tool": .string(start)], "stop": ["tool": .string(stop)]]
    }

    @Test("List tools", arguments: [
        ("droplet-list", true), ("list_droplets", true), ("getInstances", true), ("describe-workspaces", true),
        ("droplets", false), ("droplet-delete", false), ("power-off-droplet", false), ("list-and-reboot", false),
        ("compose-down", false), ("listAndTerminate", false),
    ])
    func listTools(name: String, runs: Bool) {
        #expect((DraftSafety.listTool(Self.map(name), tools: []) == .run) == runs)
    }

    @Test("The map's own start, the server's annotations and arguments that could carry a secret out are asked")
    func otherReasons() {
        #expect(DraftSafety.listTool(Self.map("list-x", start: "list-x"), tools: []) == .ask("list-x is the map’s start as well"))
        let destructive: [JSONValue] = [["name": "droplet-list", "annotations": ["destructiveHint": true]]]
        #expect(DraftSafety.listTool(Self.map("droplet-list"), tools: destructive) != .run)
        let writes: [JSONValue] = [["name": "droplet-list", "annotations": ["readOnlyHint": false]]]
        #expect(DraftSafety.listTool(Self.map("droplet-list"), tools: writes) != .run)
        #expect(DraftSafety.listTool(Self.map("droplet-list", arguments: ["url": "https://x.example/${TOKEN}"]), tools: []) != .run)
        #expect(DraftSafety.listTool(Self.map("droplet-list", arguments: ["PerPage": 200]), tools: []) == .run)
    }

    @Test("Commands", arguments: [
        ("cws list", true), ("cws ls --all", true), ("cws status devstack-1", true), ("cws get workspaces -o json", true),
        ("cws list; rm -rf ~", false), ("cws list | sh", false), ("cws list > out", false), ("cws list $(id)", false),
        ("cws list --endpoint https://x.example", false), ("cws list $TOKEN", false), ("cws destroy all", false),
        ("cws start x", false), ("cws restart", false), ("cws prune", false), ("other list", false), ("cws workspaces", false),
        ("cws list\nrm x", false), ("cws `list`", false),
    ])
    func commands(line: String, runs: Bool) {
        #expect((DraftSafety.command(line, cli: "cws") == .run) == runs)
    }

    @Test("A config's check runs its list, or each status, or a preset's own")
    func configs() {
        #expect(DraftSafety.commands(["preset": "docker", "containers": ["x"]], cli: "docker") == .run)
        #expect(DraftSafety.commands(["list": "cws list", "columns": ["id"]], cli: "cws") == .run)
        #expect(DraftSafety.commands(["workspaces": [["name": "a", "status": "cws status a"], ["name": "b", "status": "cws stop b"]]],
                                     cli: "cws") != .run)
        #expect(DraftSafety.commands(["workspaces": [["name": "a", "start": "cws start a"]]], cli: "cws") == .run)
    }

    @Test("Help words: plain, printed, at most three, and nothing destructive")
    func helpWords() {
        let seen = "Commands: list start stop destroy workspace-list"
        #expect(DraftSafety.helpWords([], seen: seen) == nil)
        #expect(DraftSafety.helpWords(["list"], seen: seen) == nil)
        #expect(DraftSafety.helpWords(["start"], seen: seen) == nil)
        #expect(DraftSafety.helpWords(["workspace-list"], seen: seen) == nil)
        #expect(DraftSafety.helpWords(["--yes"], seen: seen) != nil)
        #expect(DraftSafety.helpWords(["destroy"], seen: seen) != nil)
        #expect(DraftSafety.helpWords(["delete"], seen: seen) != nil)
        #expect(DraftSafety.helpWords(["frobnicate"], seen: seen) != nil)
        #expect(DraftSafety.helpWords(["list", "list", "list", "list"], seen: seen) != nil)
        #expect(DraftSafety.helpWords(["list;"], seen: seen) != nil)
    }
}

@Suite("A draft's secrets, redacted (#858)")
struct DraftRedactionTests {
    @Test("A long value anywhere; a short one only as a whole word; URL-encoded and base64 forms too")
    func forms() {
        let redact = DraftRedaction(["TOKEN": "dop_v1_abc/def+ghi", "PIN": "1234", "EMPTY": ""])
        #expect(redact("Bearer dop_v1_abc/def+ghi failed") == "Bearer ${TOKEN} failed")
        #expect(redact("t=dop_v1_abc%2Fdef%2Bghi") == "t=${TOKEN}")
        #expect(redact("Basic " + Data("dop_v1_abc/def+ghi".utf8).base64EncodedString()) == "Basic ${TOKEN}")
        #expect(redact("pin 1234 at port 12345") == "pin ${PIN} at port 12345")
        #expect(redact("nothing here") == "nothing here")
        let json: JSONValue = ["a": ["dop_v1_abc/def+ghi", 3], "dop_v1_abc/def+ghi": true]
        #expect(redact(json) == ["a": ["${TOKEN}", 3], "${TOKEN}": true])
    }
}
