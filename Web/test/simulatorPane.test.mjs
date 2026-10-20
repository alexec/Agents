// The Simulator pane asks for a screen only as tall as the pane in pixels (#1650): a full
// screenshot each second cost the host and the link for nothing.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

test("the screen is asked for at the pane's height in pixels, up in steps of 100", async () => {
  globalThis.window ??= { devicePixelRatio: 1 };
  globalThis.document ??= { hidden: false };
  const { maxHeight } = await load("src/views/SimulatorPane.tsx");
  assert.equal(maxHeight({ clientHeight: 420 }, 2), 900);
  assert.equal(maxHeight({ clientHeight: 400 }, 1), 400);
  assert.equal(maxHeight({ clientHeight: 0 }, 2), 100, "never nothing");
  assert.equal(maxHeight(null, 2), 100, "before the pane is drawn");
});
