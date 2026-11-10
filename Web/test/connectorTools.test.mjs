import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { byDefault, capped, defaultToolLevel, toolLevelOrder, toolLevelTitle } = await load("src/model/connectorTools.ts");

test("a tool's default is Ask when it writes and Allow when it reads, never under a cap (#4099)", () => {
  assert.equal(defaultToolLevel({ name: "a", writes: true, level: "ask" }, undefined), "ask");
  assert.equal(defaultToolLevel({ name: "a", writes: true, level: "off" }, "off"), "off");
  assert.equal(defaultToolLevel({ name: "a", writes: false, level: "allow" }, "off"), "allow");
  assert.equal(defaultToolLevel({ name: "a", writes: false, level: "ask", cap: "ask" }, undefined), "ask");
  assert.equal(byDefault("ask"), "Default (Ask)");
});

test("the levels go Allow, Ask, Off, and a looser own level is capped", () => {
  assert.deepEqual(["allow", "ask", "off"].map(toolLevelOrder), [0, 1, 2]);
  assert.equal(toolLevelTitle("off"), "Off");
  assert.equal(capped({ name: "a", writes: false, level: "ask", own: "allow", cap: "ask" }), true);
  assert.equal(capped({ name: "a", writes: false, level: "off", own: "off", cap: "ask" }), false);
});
