// A finger held on a sidebar row opens its menu (#663): after holdMilliseconds still, not once it
// has lifted or wandered off as a scroll.
import { test, mock } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

test("a hold fires once it stays put, and not when it lifts or moves first", async () => {
  const { Hold, holdMilliseconds } = await load("src/views/ContextMenu.tsx");
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    const hold = new Hold();
    let fired = 0;
    hold.start(100, 100, () => fired++);
    hold.move(104, 103);
    mock.timers.tick(holdMilliseconds - 1);
    assert.equal(fired, 0, "not before the time");
    mock.timers.tick(1);
    assert.equal(fired, 1, "a small wobble still holds");

    hold.start(100, 100, () => fired++);
    mock.timers.tick(holdMilliseconds / 2);
    hold.end();
    mock.timers.tick(holdMilliseconds);
    assert.equal(fired, 1, "lifted early: a tap, not a hold");

    hold.start(100, 100, () => fired++);
    hold.move(100, 130);
    mock.timers.tick(holdMilliseconds);
    assert.equal(fired, 1, "moved: a scroll, not a hold");

    hold.start(100, 100, () => fired++);
    hold.start(50, 50, () => fired++);
    mock.timers.tick(holdMilliseconds);
    assert.equal(fired, 2, "a new hold replaces the old one");
  } finally {
    mock.timers.reset();
  }
});
