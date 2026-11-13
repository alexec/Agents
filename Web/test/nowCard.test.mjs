// The Now card (#5033; specs/session-cards/spec.md, family 5): the goal and the plan are one card at
// the top, and what the agent does or waits on is one card at the foot, the last before the prompt
// bar, with its leases and background work as its detail. The words are the window's and the Remote's.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { load } from "./load.mjs";

const read = (path) => readFileSync(new URL(`../../${path}`, import.meta.url), "utf8");
const w = await load("src/model/nowWords.ts");

test("the Now card says what the window's and the Remote's say", () => {
  const swift = read("Shared/UI/Chat/NowCard.swift") + read("Shared/UI/Chat/LiveTile.swift");
  for (const word of [w.nowWorking, w.nowShowMore, w.nowShowLess,
    ...["screen", "browser", "simulator"].map(w.nowDriving)]) {
    assert.ok(swift.includes(`"${word}"`), word);
  }
  assert.equal(w.nowBackground(2), "In the background · 2");
  assert.ok(swift.includes('"In the background · \\(count)"'));
});

test("a plan in the transcript is one line with its count", () => {
  const steps = [{ content: "a", status: "completed", priority: "medium" }, { content: "b", status: "pending", priority: "medium" }];
  assert.equal(w.nowPlan({ state: "current", entries: steps }), "Plan · 2 steps");
  assert.equal(w.nowPlan({ state: "withdrawn", entries: steps.slice(0, 1) }), "Plan, dropped · 1 step");
  assert.match(read("Web/src/views/chat/Rows.tsx"), /return <PlanLine plan=/);
  assert.match(read("Shared/UI/Chat/TranscriptRows.swift"), /PlanLine\(plan: plan\)/);
});

test("goal and plan are one card at the top", () => {
  const chat = read("Web/src/views/Chat.tsx");
  assert.match(chat, /<NowTop agent=\{agent\} \/>/);
  assert.doesNotMatch(chat, /<GoalCard |<CurrentPlanStrip /);
  for (const file of ["App/Sources/Chat/ChatView.swift", "Remote/Sources/Chat/RemoteChatView.swift"]) {
    const view = read(file);
    assert.match(view, /NowTopCard\(agent: agent\)/, file);
    assert.doesNotMatch(view, /GoalCard\(|CurrentPlanStrip\(/, file);
  }
});

test("one Now card at the foot, after Waiting for you, and nothing of it over the prompt", () => {
  const chat = read("Web/src/views/Chat.tsx");
  const waiting = chat.indexOf('<div class="waiting" role="group"');
  const now = chat.indexOf("<NowFoot ");
  assert.ok(waiting > 0 && now > waiting, "the Now card comes after the asks");
  // The working line, the lease line, the waits and the background rows are said once, in it.
  assert.doesNotMatch(chat, /<p class="working"/);
  assert.equal(chat.match(/<BackgroundRows /g)?.length, 1);
  assert.equal(chat.match(/<LeaseLine /g)?.length, 1);
  assert.ok(chat.indexOf("<BackgroundRows ") < chat.indexOf("<NowFoot "), "background work is the Now card's detail");
  assert.doesNotMatch(chat.slice(chat.indexOf('<footer class="foot">')), /<BackgroundRows /);

  const transcript = read("Shared/UI/Chat/ChatTranscript.swift");
  assert.match(transcript, /nowCard\.inColumn\(column\)/);
  assert.doesNotMatch(transcript, /WorkingLine\(|LeaseLine\(/);
  for (const file of ["App/Sources/Chat/PromptBar.swift", "Remote/Sources/Chat/PromptBar.swift"]) {
    assert.doesNotMatch(read(file), /PromptHeader\(/, file);
  }
});

test("the Now card is on the well, with its bar in the accent and no state colour", () => {
  const css = read("Web/src/app.css");
  const card = css.match(/^\.now-card \{([^}]*)\}/m);
  assert.ok(card, "a .now-card rule");
  assert.match(card[1], /background: var\(--paper-well\)/);
  assert.match(css, /\.now-bar > span \{[^}]*background: var\(--accent\)/);
  assert.doesNotMatch(read("Shared/UI/Chat/NowCard.swift"), /StateTint|tinted\(/);
});
