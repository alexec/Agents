// The live tile (#3004, US4): the web page's tile shows the latest still, or "Mac is locked" with no
// picture (FR-012), says what the window's and the Remote's DesktopControlTile.swift says, takes
// itself away once frames stop, and is drawn at the end of the chat.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { load } from "./load.mjs";

const read = (path) => readFileSync(new URL(`../../${path}`, import.meta.url), "utf8");
const m = await load("src/model/desktopControl.ts");
const w = await load("src/model/desktopControlWords.ts");
const swift = read("Shared/UI/Chat/DesktopControlTile.swift");
const agentID = "A1";
const heard = (frame, heardAt = 1_000) => ({ host: "mac", frame: { agentID, capturedAt: 0, ...frame }, heardAt });

test("a frame with a picture shows it, with the narration", () => {
  const s = m.tileState(heard({ image: "ZmFrZQ==", narration: "Clicked Save in TextEdit." }), "mac", agentID, 2_000);
  assert.deepEqual(s, { kind: "picture", src: "data:image/jpeg;base64,ZmFrZQ==", narration: "Clicked Save in TextEdit." });
});

test("a locked screen shows the placeholder and never a picture", () => {
  const s = m.tileState(heard({ locked: true, image: "ZmFrZQ==", narration: "Typed into TextEdit." }), "mac", agentID, 2_000);
  assert.equal(s.kind, "locked");
  assert.equal(s.src, undefined);
  assert.equal(s.narration, "Typed into TextEdit.");
});

test("the tile goes once frames stop, and is not another agent's or another host's", () => {
  const f = heard({ image: "ZmFrZQ==" });
  assert.equal(m.tileState(f, "mac", agentID, 1_000 + m.staleAfterMs - 1).kind, "picture");
  assert.equal(m.tileState(f, "mac", agentID, 1_000 + m.staleAfterMs).kind, "hidden");
  assert.equal(m.tileState(f, "mac", "B2", 2_000).kind, "hidden");
  assert.equal(m.tileState(f, "server", agentID, 2_000).kind, "hidden");
  assert.equal(m.tileState(null, "mac", agentID, 2_000).kind, "hidden");
  assert.equal(m.tileState(heard({}), "mac", agentID, 2_000).kind, "waiting");
});

test("the tile's words are the window's", () => {
  for (const words of [w.tileTitle, w.tileLocked, w.tileLockedBody, w.tileWaiting]) {
    assert.ok(swift.includes(`"${words}"`), words);
  }
});

test("the store keeps the latest frame and the chat draws the tile while the agent runs", () => {
  const store = read("Web/src/model/store.ts");
  assert.match(store, /case "desktopControl\/liveFrame":\s*this\.liveFrame\.value = \{ host, frame: params as DesktopControlLiveFrame, heardAt: Date\.now\(\) \};/);
  const chat = read("Web/src/views/Chat.tsx");
  assert.match(chat, /agent && agent\.state === "running" \? \[\{\s*key: `live:\$\{agent\.id\}`/);
});
