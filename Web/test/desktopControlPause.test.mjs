// Pause on touch (#3004, US3): the web page's card says what the window's and the Remote's
// DesktopControlPauseCard.swift says, offers both answers, and is drawn at the end of the chat.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { load } from "./load.mjs";

const read = (path) => readFileSync(new URL(`../../${path}`, import.meta.url), "utf8");
const w = await load("src/model/desktopControlWords.ts");
const swift = read("Shared/UI/Chat/DesktopControlPauseCard.swift");

test("the pause card's words are the window's", () => {
  for (const words of [w.pauseBody, w.resumeLabel, w.takeOverLabel, w.takeOverHelp]) {
    assert.ok(swift.includes(`"${words}"`), words);
  }
  assert.equal(w.pauseTitle("Preview"), "Paused driving Preview: you used the mouse or keyboard");
  assert.ok(swift.includes('"Paused driving \\(app): you used the mouse or keyboard"'));
  assert.equal(w.pauseTitle(""), "Paused: you used the mouse or keyboard");
  assert.ok(swift.includes('"Paused: you used the mouse or keyboard"'));
});

test("the card answers with desktopControl/resume and desktopControl/takeOver, and the chat draws it", () => {
  const card = read("Web/src/views/DesktopControlPauseCard.tsx");
  assert.ok(card.includes('answer("desktopControl/resume")'));
  assert.ok(card.includes('answer("desktopControl/takeOver")'));
  const chat = read("Web/src/views/Chat.tsx");
  assert.match(chat, /agent\?\.desktopControlPause \? \[\{\s*key: `screen:\$\{agent\.id\}`/);
});
