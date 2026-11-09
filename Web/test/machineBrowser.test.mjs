// The Agent Browser tab (#3528): where a click lands in the page, what a key says, and the words the
// window's AgentBrowserPane.swift says too.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { load } from "./load.mjs";

const m = await load("src/model/machineBrowser.ts");
const read = (path) => readFileSync(new URL(`../../${path}`, import.meta.url), "utf8");

test("a click lands where the page is drawn, and nowhere outside it", () => {
  const page = { width: 800, height: 600 };
  const view = { width: 400, height: 600 };
  assert.deepEqual(m.fitted(page, view), { x: 0, y: 150, width: 400, height: 300 });
  assert.deepEqual(m.pagePoint({ x: 200, y: 300 }, view, page), { x: 400, y: 300 });
  assert.equal(m.pagePoint({ x: 200, y: 100 }, view, page), null);
  assert.equal(m.pagePoint({ x: 1, y: 1 }, view, { width: 0, height: 0 }), null);
});

test("a key is named as the page names it, with text only when it types", () => {
  const base = { altKey: false, ctrlKey: false, metaKey: false, shiftKey: false };
  assert.deepEqual(m.keyInput({ ...base, key: "a", code: "KeyA", keyCode: 65 }, true),
    { kind: "key", type: "keyDown", key: "a", code: "KeyA", keyCode: 65, text: "a", modifiers: 0 });
  assert.equal(m.keyInput({ ...base, key: "a", code: "KeyA", keyCode: 65 }, false).text, undefined);
  assert.equal(m.keyInput({ ...base, key: "Backspace", code: "Backspace", keyCode: 8 }, true).text, undefined);
  const control = m.keyInput({ ...base, ctrlKey: true, key: "a", code: "KeyA", keyCode: 65 }, true);
  assert.equal(control.text, undefined);
  assert.equal(control.modifiers, 2);
  assert.equal(m.modifiers({ altKey: true, ctrlKey: false, metaKey: true, shiftKey: true }), 13);
});

test("what a touch keyboard types reaches the page as text and keys (#4088)", () => {
  assert.deepEqual(m.touchTyped("insertText", "é"), [{ kind: "text", text: "é" }]);
  assert.deepEqual(m.touchTyped("insertText", null), []);
  const back = m.touchTyped("deleteContentBackward", null);
  assert.deepEqual(back.map((k) => [k.type, k.key, k.keyCode]), [["keyDown", "Backspace", 8], ["keyUp", "Backspace", 8]]);
  const enter = m.touchTyped("insertLineBreak", null);
  assert.equal(enter[0].key, "Enter");
  assert.equal(enter[0].text, "\r");
  assert.equal(enter[1].text, undefined);
  assert.deepEqual(m.touchTyped("formatBold", null), []);
});

test("a tap focuses the hidden field inside the tap, and the host's editing false closes it (#4088)", () => {
  const pane = read("Web/src/views/AgentBrowserPane.tsx");
  assert.match(pane, /if \(touch\.current && keys\.current\) keys\.current\.focus/);
  assert.match(pane, /said\?\.editing === false/);
});

test("the take-over tab says what the window's pane says (#4141)", () => {
  const swift = read("App/Sources/Sidebar/AgentBrowserPane.swift") + read("App/Sources/Sidebar/SidebarState.swift");
  for (const said of [m.words.stoppedTitle, m.words.stopped, m.words.failedTitle, m.words.failed,
    m.words.starting, m.words.loading]) {
    assert.ok(swift.includes(`"${said}"`), said);
  }
});

test("the pane says which other session holds the browser, and nothing for its own (#3916)", () => {
  const own = "8a3c1e2f-0000-4000-8000-000000000001";
  const other = "8A3C1E2F-0000-4000-8000-000000000002";
  assert.equal(m.otherHolder({ status: "running" }, own), null);
  assert.equal(m.otherHolder({ status: "running", holder: own.toUpperCase(), holderTitle: "Mine" }, own), null);
  assert.deepEqual(m.otherHolder({ status: "running", holder: other, holderTitle: "Fix the login" }, own),
    { id: other, title: "Fix the login" });
  assert.deepEqual(m.otherHolder({ status: "running", holder: other }, own), { id: other, title: "Another session" });
  assert.equal(m.words.noTabTitle, "This session's agent has not used the browser");
});
