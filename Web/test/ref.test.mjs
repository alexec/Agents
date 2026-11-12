// A ref (#4727): the same rows as Go/wire/ref_test.go and WireRefTests.swift.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const r = await load("src/protocol/ref.ts");

test("ref: every row of the spec's table parses and writes back", () => {
  const rows = [
    ["github:pr:alexec/agents#4702", "github:pr:alexec/agents#4702", ["github", "pr", "alexec/agents", "4702"]],
    ["github:issue:alexec/agents#4724", "github:issue:alexec/agents#4724", ["github", "issue", "alexec/agents", "4724"]],
    ["github:branch:alexec/agents#agents/fix-640", "github:branch:alexec/agents#agents/fix-640", ["github", "branch", "alexec/agents", "agents/fix-640"]],
    ["github:run:alexec/agents#19283746", "github:run:alexec/agents#19283746", ["github", "run", "alexec/agents", "19283746"]],
    ["gitlab:mr:group/sub/repo#45", "gitlab:mr:group/sub/repo#45", ["gitlab", "mr", "group/sub/repo", "45"]],
    ["jira:issue:ABC#ABC-9", "jira:issue:abc#ABC-9", ["jira", "issue", "abc", "ABC-9"]],
    ["linear:issue:ENG#ENG-4", "linear:issue:eng#ENG-4", ["linear", "issue", "eng", "ENG-4"]],
    ["slack:message:T01ABC/C02DEF#1699999999.000100", "slack:message:t01abc/c02def#1699999999.000100", ["slack", "message", "t01abc/c02def", "1699999999.000100"]],
    ["email:message:alex@example.com#<Ab.C@mail.example.com>", "email:message:alex@example.com#<Ab.C@mail.example.com>", ["email", "message", "alex@example.com", "<Ab.C@mail.example.com>"]],
    ["agents:session:alexec/agents#7F3C-ab", "agents:session:alexec/agents#7F3C-ab", ["agents", "session", "alexec/agents", "7F3C-ab"]],
    ["agents:machine:#mac-mini", "agents:machine:#mac-mini", ["agents", "machine", "", "mac-mini"]],
    ["github:branch:alexec/agents#a/b#c:d", "github:branch:alexec/agents#a/b#c:d", ["github", "branch", "alexec/agents", "a/b#c:d"]],
    ["GitHub:PR:Alexec/Agents#4702", "github:pr:alexec/agents#4702", ["github", "pr", "alexec/agents", "4702"]],
  ];
  for (const [input, out, [provider, type, topic, id]] of rows) {
    const got = r.parseRef(input);
    assert.deepEqual(got, { provider, type, topic, id }, input);
    assert.equal(r.formatRef(got), out, input);
    assert.deepEqual(r.parseRef(r.formatRef(got)), got, input);
  }
});

test("ref: what the full form refuses", () => {
  for (const input of [
    "",
    "github:pr:alexec/agents",
    "github:pr:alexec/agents#",
    "github:alexec/agents#4702",
    "github:pr:x:alexec/agents#1",
    "git hub:pr:alexec/agents#1",
    "github:p_r:alexec/agents#1",
    ":pr:alexec/agents#1",
    "github::alexec/agents#1",
    "#4702",
    "github:pr:" + "a".repeat(r.maxRefLength) + "#1",
  ]) {
    assert.throws(() => r.parseRef(input), undefined, input);
  }
});

test("ref: the short forms parse to the full ref", () => {
  const typeOf = (_p, _t, id) => (id === "7" ? "pr" : id === "404" ? undefined : "issue");
  const origin = { provider: "github", topic: "alexec/agents", typeOf };
  const rows = [
    ["github:pr:alexec/agents#4702", {}, "github:pr:alexec/agents#4702"],
    ["#123", origin, "github:issue:alexec/agents#123"],
    ["#7", origin, "github:pr:alexec/agents#7"],
    ["P#123", origin, "github:pr:alexec/agents#123"],
    ["p#123", origin, "github:pr:alexec/agents#123"],
    ["P#45", { provider: "gitlab", topic: "group/sub/repo" }, "gitlab:mr:group/sub/repo#45"],
    ["Owner/Repo#123", origin, "github:issue:owner/repo#123"],
    ["github:Alexec/Agents#7", { typeOf }, "github:pr:alexec/agents#7"],
    ["  #123 ", origin, "github:issue:alexec/agents#123"],
  ];
  for (const [input, c, want] of rows) {
    assert.equal(r.formatRef(r.parseShortRef(input, c)), want, input);
  }
  for (const [input, c] of [
    ["#123", {}],
    ["P#123", { provider: "github" }],
    ["owner/repo#1", {}],
    ["#123", { provider: "github", topic: "a/b" }],
    ["#404", origin],
    ["123", origin],
    ["#", origin],
    ["X#123", origin],
  ]) {
    assert.throws(() => r.parseShortRef(input, c), undefined, input);
  }
});

test("ref: the old lineage forms read as Go's RefFromLineage reads them (#4800)", () => {
  const rows = [
    ["issue", "github:alexec/agents#123", "github:issue:alexec/agents#123"],
    ["pr", "github:alexec/Agents#4702", "github:pr:alexec/agents#4702"],
    ["pr", "gitlab:group/sub/repo!45", "gitlab:mr:group/sub/repo#45"],
    ["issue", "linear:ENG-4", "linear:issue:eng#ENG-4"],
    ["issue", "jira:ABC-9", "jira:issue:abc#ABC-9"],
    ["issue", "azureboards:project#12", "azureboards:issue:project#12"],
    ["session", "session:7F3C", "agents:session:alexec/agents#7F3C"],
    ["release", "github:alexec/agents/release/v1.2.0", "github:release:alexec/agents#v1.2.0"],
    ["doc", "github:alexec/agents/doc/specs/a/spec.md", "github:doc:alexec/agents#specs/a/spec.md"],
    ["doc", "file:/Users/me/folder/docs/a.md", "file:doc:#/Users/me/folder/docs/a.md"],
    ["doc", "https://www.notion.so/Page-1", "web:doc:www.notion.so#/Page-1"],
    ["ci-run", "github:alexec/agents/actions/run/19283746", "github:run:alexec/agents#19283746"],
    ["ci-run", "azuredevops:org/proj/repo/builds/9", "azuredevops:run:org/proj/repo#9"],
    ["deploy", "testflight:com.Example.App/42", "testflight:deploy:com.example.app#42"],
    ["target", "target:testflight:com.Example.App", "testflight:target:#com.example.app"],
    ["health", "sentry:acme/12345", "sentry:issue:acme#12345"],
    ["health", "betterstack:987", "betterstack:incident:#987"],
    ["workflow", "workflow:/Users/me/folder/nightly", "agents:workflow:alexec/agents#/Users/me/folder/nightly"],
    ["workflow-run", "run:R1", "agents:workflow-run:alexec/agents#R1"],
    ["repo", "github:alexec/Agents", "github:repo:#alexec/agents"],
    ["repo", "linear:ENG", "linear:repo:#eng"],
    ["pr", "github:pr:alexec/agents#4702", "github:pr:alexec/agents#4702"],
  ];
  for (const [kind, old, want] of rows) {
    const got = r.refFromLineage(kind, old, "Alexec/Agents");
    assert.equal(got && r.formatRef(got), want, `${kind} ${old}`);
  }
  for (const [kind, old] of [["release", "github:alexec/agents"], ["issue", "linear:ENG"], ["repo", "github:o/r#12"], ["session", "nonsense"]]) {
    assert.equal(r.refFromLineage(kind, old), undefined, `${kind} ${old}`);
  }
  assert.equal(r.sessionIdOf("agents:session:alexec/agents#A1"), "A1");
  assert.equal(r.sessionIdOf("session:A1"), "A1");
  assert.equal(r.sessionIdOf("github:issue:o/r#1"), undefined);
  assert.equal(r.formatRef(r.repoOfRef(r.anyLineageRef("github:alexec/agents#12"))), "github:repo:#alexec/agents");
});

test("ref: legacyRef writes the old form back, for the page's words (#4800)", () => {
  for (const [full, old] of [
    ["github:issue:alexec/agents#12", "github:alexec/agents#12"], ["gitlab:mr:g/r#4", "gitlab:g/r!4"],
    ["linear:issue:eng#ENG-4", "linear:ENG-4"], ["agents:session:alexec/agents#A1", "session:A1"],
    ["github:release:alexec/agents#v1.2.0", "github:alexec/agents/release/v1.2.0"],
    ["github:run:alexec/agents#9", "github:alexec/agents/actions/run/9"], ["gitlab:run:g/r#9", "gitlab:g/r/pipelines/9"],
    ["testflight:deploy:com.x.app#42", "testflight:com.x.app/42"], ["testflight:target:#com.x.app", "target:testflight:com.x.app"],
    ["sentry:issue:acme#42", "sentry:acme/42"], ["betterstack:incident:#7", "betterstack:7"],
    ["web:doc:www.notion.so#/P-1", "https://www.notion.so/P-1"], ["github:doc:o/r#specs/a.md", "github:o/r/doc/specs/a.md"],
    ["github:repo:#alexec/agents", "github:alexec/agents"], ["github:alexec/agents#12", "github:alexec/agents#12"],
  ]) assert.equal(r.legacyRef(full), old, full);
});
