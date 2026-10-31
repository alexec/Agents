// PoolWords.runtimeName on the page: the catalog's name, else the id as written.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { runtimeName } = await load("src/model/switchNote.ts");

test("the catalog's names, else the id as written", () => {
  assert.equal(runtimeName("opencode"), "OpenCode");
  assert.equal(runtimeName("somebody-new"), "somebody-new");
});
