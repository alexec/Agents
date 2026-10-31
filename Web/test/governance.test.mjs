// Catalogue governance (#2019, M5): how a request, an approval and a row of who uses what read.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const m = await load("src/model/governance.ts");

const request = (over) => ({ id: "r1", kind: "mcp", name: "github", user: "sam", userName: "Sam", at: 10, state: "waiting", ...over });

test("a waiting request reads with why, and a person's own by its state", () => {
  assert.equal(m.requestWords(request({ why: "to review pull requests" })), "Sam asks for the MCP server github: to review pull requests");
  assert.equal(m.requestWords(request({ kind: "skills", name: "review" })), "Sam asks for the skill review");
  assert.equal(m.mineWords(request()), "The MCP server github: waiting for an admin");
  assert.equal(m.mineWords(request({ state: "approved", groupName: "Platform" })),
    "The MCP server github: approved for Platform. Add it as you add any MCP server.");
  assert.equal(m.mineWords(request({ kind: "skills", name: "review", state: "approved" })),
    "The skill review: approved for you. Add it as you add any skill.");
  // #2434: the Policy's marketplaces still decide.
  assert.equal(m.mineWords(request({ state: "approved" }), true),
    "The MCP server github: approved for you. Add it as you add any MCP server. Your organisation's Policy still blocks it if no marketplace it allows has it.");
  assert.equal(m.mineWords(request({ kind: "skills", name: "review", state: "refused" })), "The skill review: refused");
});

test("who uses an item names at most three people", () => {
  const people = ["Bea", "Cy", "Dee", "Sam", "Uma"].map((name) => ({ id: name.toLowerCase(), name }));
  assert.equal(m.usersWords({ kind: "mcp", name: "github", version: "1", machines: 1, people: people.slice(0, 1) }), "1 machine: Bea");
  assert.equal(m.usersWords({ kind: "mcp", name: "github", version: "1", machines: 6, people }), "6 machines: Bea, Cy, Dee and 2 more");
  assert.equal(m.usersWords({ kind: "mcp", name: "github", version: "1", machines: 2, people: [] }), "2 machines");
});

test("the waiting list keeps waiting requests only, oldest first", () => {
  let list = m.withGovernanceRequest([], request({ id: "b", at: 20 }));
  list = m.withGovernanceRequest(list, request({ id: "a", at: 10 }));
  assert.deepEqual(list.map((r) => r.id), ["a", "b"]);
  list = m.withGovernanceRequest(list, request({ id: "a", at: 10, state: "approved" }));
  assert.deepEqual(list.map((r) => r.id), ["b"]);
});

test("an approval is for its group, or else its person", () => {
  assert.equal(m.approvalFor({ kind: "mcp", name: "github", group: "g1", groupName: "Platform", by: "Alex", at: 1 }), "Platform");
  assert.equal(m.approvalFor({ kind: "mcp", name: "github", user: "sam", userName: "Sam", by: "Alex", at: 1 }), "Sam");
});

test("Take Back… asks first, and names what and whose (#2438)", () => {
  assert.match(m.takeBackQuestion("mcp", "github", "Platform"), /^Take back the MCP server github for Platform\? /);
  assert.match(m.takeBackQuestion("skills", "pdf", "Sam"), /^Take back the skill pdf for Sam\? /);
});
