// The live tile (#3004, #4140): the web page's tile shows the newest fresh frame of what an agent
// drives (the screen, the agent browser, a simulator), or "Mac is locked" with no picture (FR-012),
// says what the window's and the Remote's LiveTile.swift says, takes itself away once frames stop,
// and is drawn at the end of the chat.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { load } from "./load.mjs";

const read = (path) => readFileSync(new URL(`../../${path}`, import.meta.url), "utf8");
// The store and its slices (#5384).
const readStore = () => [read("Web/src/model/store.ts"), ...readdirSync(new URL("../src/model/store/", import.meta.url)).map((name) => read(`Web/src/model/store/${name}`))].join("\n");
const m = await load("src/model/liveTile.ts");
const w = await load("src/model/liveTileWords.ts");
const swift = read("Shared/UI/Chat/LiveTile.swift");
const agentID = "A1";
const heard = (frame, heardAt = 1_000, host = "mac") =>
  ({ host, frame: { source: "screen", agentID, capturedAt: 0, ...frame }, heardAt });

test("a frame with a picture shows it, with the narration", () => {
  const s = m.tileState(heard({ image: "ZmFrZQ==", narration: "Clicked Save in TextEdit." }).frame);
  assert.deepEqual(s, { kind: "picture", src: "data:image/jpeg;base64,ZmFrZQ==", narration: "Clicked Save in TextEdit." });
});

test("a locked screen shows the placeholder and never a picture", () => {
  const s = m.tileState(heard({ locked: true, image: "ZmFrZQ==", narration: "Typed into TextEdit." }).frame);
  assert.equal(s.kind, "locked");
  assert.equal(s.src, undefined);
  assert.equal(s.narration, "Typed into TextEdit.");
  assert.equal(m.tileState(heard({}).frame).kind, "waiting");
});

test("a source goes once its frames stop, and is not another agent's or another host's", () => {
  const frames = { screen: heard({ image: "ZmFrZQ==" }) };
  assert.equal(m.freshFrames(frames, "mac", agentID, 1_000 + m.staleAfterMs - 1).length, 1);
  assert.equal(m.freshFrames(frames, "mac", agentID, 1_000 + m.staleAfterMs).length, 0);
  assert.equal(m.freshFrames(frames, "mac", "B2", 2_000).length, 0);
  assert.equal(m.freshFrames(frames, "server", agentID, 2_000).length, 0);
  assert.equal(m.shownFrame([], null), undefined);
});

test("two sources: the newest is in front, unless the person chose one that is still fresh", () => {
  const frames = {
    screen: heard({ source: "screen" }, 5_000),
    browser: heard({ source: "browser", title: "Example Domain" }, 9_000),
    simulator: heard({ source: "simulator" }, 1_000),
  };
  const fresh = m.freshFrames(frames, "mac", agentID, 17_000);
  assert.deepEqual(fresh.map((h) => h.frame.source), ["browser", "screen"]);
  assert.equal(m.shownFrame(fresh, null).frame.source, "browser");
  assert.equal(m.shownFrame(fresh, "screen").frame.source, "screen");
  assert.equal(m.shownFrame(fresh, "simulator").frame.source, "browser", "a stale choice gives way");
});

test("a host from before live/frame still fills the screen's", () => {
  assert.deepEqual(m.fromDesktopControl({ agentID, capturedAt: 0, image: "x" }), { agentID, capturedAt: 0, image: "x", source: "screen" });
});

test("the tile names its source as the window does", () => {
  assert.equal(w.tileName({ source: "screen", agentID, capturedAt: 0, title: "ignored" }), "Screen");
  assert.equal(w.tileName({ source: "browser", agentID, capturedAt: 0, title: "Example Domain" }), "Example Domain");
  assert.equal(w.tileName({ source: "browser", agentID, capturedAt: 0 }), "Agent Browser");
  assert.equal(w.tileName({ source: "simulator", agentID, capturedAt: 0, title: "iPhone 17" }), "iPhone 17");
  const words = [w.tileScreen, w.tileBrowser, w.tileSimulator, w.tileLocked, w.tileLockedBody, w.tileOpen, w.tileSwitch,
    ...["screen", "browser", "simulator"].flatMap((s) => [w.tileWaiting(s), w.tileOpenHelp(s)])];
  for (const word of words) assert.ok(swift.includes(`"${word}"`), word);
});

test("the store keeps each source's latest frame and the chat draws the tile while the agent runs", () => {
  const store = readStore();
  assert.match(store, /case "live\/frame": \{\s*const frame = params as LiveFrame;\s*this\.liveFrames\.value = \{ \.\.\.this\.liveFrames\.peek\(\), \[frame\.source\]:/);
  const chat = read("Web/src/views/Chat.tsx");
  // A part of the Now card at the foot (#5033), not a card in Waiting for you.
  assert.match(chat, /const drives = !!agent && agent\.state === "running" && freshFrames\(/);
  assert.match(chat, /\.\.\.\(drives \? \[<LiveTile key="live"/);
});
