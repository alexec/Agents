import Foundation
import Testing
@testable import AgentsKitCore

/// A ref (#4727): the same rows as `Go/wire/ref_test.go` and `Web/test/ref.test.mjs`.
@Suite("Wire ref")
struct WireRefTests {
    @Test func everyRowOfTheSpecTable() throws {
        let rows: [(String, String, [String])] = [
            ("github:pr:alexec/agents#4702", "github:pr:alexec/agents#4702", ["github", "pr", "alexec/agents", "4702"]),
            ("github:issue:alexec/agents#4724", "github:issue:alexec/agents#4724", ["github", "issue", "alexec/agents", "4724"]),
            ("github:branch:alexec/agents#agents/fix-640", "github:branch:alexec/agents#agents/fix-640", ["github", "branch", "alexec/agents", "agents/fix-640"]),
            ("github:run:alexec/agents#19283746", "github:run:alexec/agents#19283746", ["github", "run", "alexec/agents", "19283746"]),
            ("gitlab:mr:group/sub/repo#45", "gitlab:mr:group/sub/repo#45", ["gitlab", "mr", "group/sub/repo", "45"]),
            ("jira:issue:ABC#ABC-9", "jira:issue:abc#ABC-9", ["jira", "issue", "abc", "ABC-9"]),
            ("linear:issue:ENG#ENG-4", "linear:issue:eng#ENG-4", ["linear", "issue", "eng", "ENG-4"]),
            ("slack:message:T01ABC/C02DEF#1699999999.000100", "slack:message:t01abc/c02def#1699999999.000100", ["slack", "message", "t01abc/c02def", "1699999999.000100"]),
            ("email:message:alex@example.com#<Ab.C@mail.example.com>", "email:message:alex@example.com#<Ab.C@mail.example.com>", ["email", "message", "alex@example.com", "<Ab.C@mail.example.com>"]),
            ("agents:session:alexec/agents#7F3C-ab", "agents:session:alexec/agents#7F3C-ab", ["agents", "session", "alexec/agents", "7F3C-ab"]),
            ("agents:machine:#mac-mini", "agents:machine:#mac-mini", ["agents", "machine", "", "mac-mini"]),
            ("github:branch:alexec/agents#a/b#c:d", "github:branch:alexec/agents#a/b#c:d", ["github", "branch", "alexec/agents", "a/b#c:d"]),
            ("GitHub:PR:Alexec/Agents#4702", "github:pr:alexec/agents#4702", ["github", "pr", "alexec/agents", "4702"]),
        ]
        for (input, out, parts) in rows {
            let r = try WireRef(parsing: input)
            #expect(r == WireRef(provider: parts[0], type: parts[1], topic: parts[2], id: parts[3]), "\(input)")
            #expect(r.description == out, "\(input)")
            #expect(try WireRef(parsing: r.description) == r, "\(input)")
        }
    }

    @Test func whatTheFullFormRefuses() {
        for input in [
            "", "github:pr:alexec/agents", "github:pr:alexec/agents#", "github:alexec/agents#4702",
            "github:pr:x:alexec/agents#1", "git hub:pr:alexec/agents#1", "github:p_r:alexec/agents#1",
            ":pr:alexec/agents#1", "github::alexec/agents#1", "#4702",
            "github:pr:" + String(repeating: "a", count: WireRef.maxLength) + "#1",
        ] {
            #expect(throws: WireRef.ParseError.self, "\(input)") { try WireRef(parsing: input) }
        }
    }

    @Test func shortFormsParseToTheFullRef() throws {
        let typeOf: @Sendable (String, String, String) -> String? = { _, _, id in
            id == "7" ? "pr" : id == "404" ? nil : "issue"
        }
        let origin = WireRef.Context(provider: "github", topic: "alexec/agents", typeOf: typeOf)
        let rows: [(String, WireRef.Context, String)] = [
            ("github:pr:alexec/agents#4702", .init(), "github:pr:alexec/agents#4702"),
            ("#123", origin, "github:issue:alexec/agents#123"),
            ("#7", origin, "github:pr:alexec/agents#7"),
            ("P#123", origin, "github:pr:alexec/agents#123"),
            ("p#123", origin, "github:pr:alexec/agents#123"),
            ("P#45", .init(provider: "gitlab", topic: "group/sub/repo"), "gitlab:mr:group/sub/repo#45"),
            ("Owner/Repo#123", origin, "github:issue:owner/repo#123"),
            ("github:Alexec/Agents#7", .init(typeOf: typeOf), "github:pr:alexec/agents#7"),
            ("  #123 ", origin, "github:issue:alexec/agents#123"),
        ]
        for (input, c, want) in rows {
            #expect(try WireRef(short: input, context: c).description == want, "\(input)")
        }
        let refused: [(String, WireRef.Context)] = [
            ("#123", .init()), ("P#123", .init(provider: "github")), ("owner/repo#1", .init()),
            ("#123", .init(provider: "github", topic: "a/b")), ("#404", origin), ("123", origin),
            ("#", origin), ("X#123", origin),
        ]
        for (input, c) in refused {
            #expect(throws: WireRef.ParseError.self, "\(input)") { try WireRef(short: input, context: c) }
        }
    }

    @Test func onTheWireItIsTheFullForm() throws {
        let r = try JSONDecoder().decode([WireRef].self, from: Data(#"["github:PR:alexec/agents#4702"]"#.utf8))
        #expect(r == [WireRef(provider: "github", type: "pr", topic: "alexec/agents", id: "4702")])
        #expect(String(decoding: try JSONEncoder().encode(r), as: UTF8.self) == #"["github:pr:alexec\/agents#4702"]"#)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([WireRef].self, from: Data(##"["#4702"]"##.utf8)) }
    }

    /// #4800: the old lineage forms, as Go's `TestRefFromLineage` reads them.
    @Test func theOldLineageForms() {
        let rows: [(String, String, String)] = [
            ("issue", "github:alexec/agents#123", "github:issue:alexec/agents#123"),
            ("pr", "github:alexec/Agents#4702", "github:pr:alexec/agents#4702"),
            ("pr", "gitlab:group/sub/repo!45", "gitlab:mr:group/sub/repo#45"),
            ("issue", "linear:ENG-4", "linear:issue:eng#ENG-4"),
            ("issue", "jira:ABC-9", "jira:issue:abc#ABC-9"),
            ("issue", "azureboards:project#12", "azureboards:issue:project#12"),
            ("session", "session:7F3C", "agents:session:alexec/agents#7F3C"),
            ("release", "github:alexec/agents/release/v1.2.0", "github:release:alexec/agents#v1.2.0"),
            ("doc", "github:alexec/agents/doc/specs/a/spec.md", "github:doc:alexec/agents#specs/a/spec.md"),
            ("doc", "file:/Users/me/folder/docs/a.md", "file:doc:#/Users/me/folder/docs/a.md"),
            ("doc", "https://www.notion.so/Page-1", "web:doc:www.notion.so#/Page-1"),
            ("ci-run", "github:alexec/agents/actions/run/19283746", "github:run:alexec/agents#19283746"),
            ("ci-run", "gitlab:group/repo/pipelines/9", "gitlab:run:group/repo#9"),
            ("deploy", "testflight:com.Example.App/42", "testflight:deploy:com.example.app#42"),
            ("target", "target:testflight:com.Example.App", "testflight:target:#com.example.app"),
            ("health", "sentry:acme/12345", "sentry:issue:acme#12345"),
            ("health", "betterstack:987", "betterstack:incident:#987"),
            ("workflow", "workflow:/Users/me/folder/nightly", "agents:workflow:alexec/agents#/Users/me/folder/nightly"),
            ("workflow-run", "run:R1", "agents:workflow-run:alexec/agents#R1"),
            ("repo", "github:alexec/Agents", "github:repo:#alexec/agents"),
            ("pr", "github:pr:alexec/agents#4702", "github:pr:alexec/agents#4702"),
        ]
        for (kind, old, want) in rows {
            #expect(WireRef(lineageKind: kind, ref: old, topic: "Alexec/Agents")?.description == want, "\(kind) \(old)")
        }
        for (kind, old) in [("release", "github:alexec/agents"), ("issue", "linear:ENG"), ("repo", "github:o/r#12"), ("session", "nonsense")] {
            #expect(WireRef(lineageKind: kind, ref: old) == nil, "\(kind) \(old)")
        }
        #expect(WireRef.sessionID(fromRef: "agents:session:alexec/agents#A1") == "A1")
        #expect(WireRef.sessionID(fromRef: "session:A1") == "A1")
        #expect(WireRef.sessionID(fromRef: "github:issue:o/r#1") == nil)
        #expect(WireRef(anyLineage: "github:alexec/agents#12")?.repoRef?.description == "github:repo:#alexec/agents")
        #expect(WireRef(anyLineage: "github:alexec/agents/release/v1")?.type == "release")
        for (full, old) in [
            ("github:issue:alexec/agents#12", "github:alexec/agents#12"), ("gitlab:mr:g/r#4", "gitlab:g/r!4"),
            ("agents:session:alexec/agents#A1", "session:A1"), ("github:run:o/r#9", "github:o/r/actions/run/9"),
            ("testflight:deploy:com.x.app#42", "testflight:com.x.app/42"), ("sentry:issue:acme#42", "sentry:acme/42"),
            ("github:repo:#alexec/agents", "github:alexec/agents"), ("github:alexec/agents#12", "github:alexec/agents#12"),
        ] {
            #expect(WireRef.legacy(full) == old, "\(full)")
        }
        // The words a page shows are the same in either form.
        for (full, old) in [("github:issue:alexec/agents#12", "github:alexec/agents#12"), ("gitlab:mr:g/r#4", "gitlab:g/r!4"),
                            ("linear:issue:eng#ENG-4", "linear:ENG-4"), ("github:release:o/r#v1.2.0", "github:o/r/release/v1.2.0")] {
            #expect(WorkList.shortRef(full) == WorkList.shortRef(old), "\(full)")
            #expect(WorkList.number(full) == WorkList.number(old), "\(full)")
            #expect(WorkList.forgeName(full) == WorkList.forgeName(old), "\(full)")
            #expect(WorkList.repoName(WorkList.repo(of: full)) == WorkList.repoName(WorkList.repo(of: old)), "\(full)")
        }
    }
}
