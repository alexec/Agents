// The lineage nodes the web page links to: a node's address and a session's machine.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const l = await load("src/model/lineage.ts");

const S = "11111111-1111-4111-8111-111111111111";

test("an issue, a PR, a milestone or a release on GitHub has its address; a session has none", () => {
  assert.equal(l.lineageUrl({ kind: "issue", ref: "github:alexec/agents#12" }), "https://github.com/alexec/agents/issues/12");
  assert.equal(l.lineageUrl({ kind: "pr", ref: "github:alexec/agents#34" }), "https://github.com/alexec/agents/pull/34");
  assert.equal(l.lineageUrl({ kind: "session", ref: `session:${S}` }), undefined);
  assert.equal(l.lineageUrl({ kind: "milestone", ref: "github:alexec/agents/milestone/15" }), "https://github.com/alexec/agents/milestone/15");
  assert.equal(l.lineageUrl({ kind: "release", ref: "github:alexec/agents/release/v0.14.0" }), "https://github.com/alexec/agents/releases/tag/v0.14.0");
});

test("a session's machine is found among every machine's sessions, not only the newest (#3156)", () => {
  const many = Array.from({ length: 20 }, (_, i) => ({ id: `old-${i}` }));
  const agents = { mac: many, linux: [{ id: "a" }, { id: S }] };
  assert.equal(l.sessionHost(agents, S), "linux");
  assert.equal(l.sessionHost(agents, "old-19"), "mac");
  assert.equal(l.sessionHost(agents, "nowhere"), undefined);
});
