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
