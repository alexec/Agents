// The Docs slot (#3248): its heading and lines, its docs connectors, and never a slot a project sets.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/connectorSetup.ts");

test("the Docs slot says what it read, and its connectors", () => {
  const read = { slot: "docs", choice: "This folder and Notion", state: "read", servers: ["notion"] };
  assert.equal(c.heading("docs"), "Docs");
  assert.equal(c.title(read), "This folder and Notion");
  assert.equal(c.line(read, "walk", undefined, false), c.docs.none);
  assert.equal(c.line({ ...read, state: "skipped" }, "walk", undefined, false),
    "Agents won't look for docs before they work. Nothing is turned on.");
  assert.equal(c.docs.servers(read.servers), "Connectors: notion");
  assert.equal(c.docs.servers([]), undefined);
  assert.equal(c.proofLead("docs"), "Newest");
});

test("a project sets only the forge's slots", () => {
  assert.deepEqual(["tasks", "codeReview", "ci", "docs", "workspace"].filter(c.isProjects), ["tasks", "codeReview", "ci"]);
});
