// The one Ask card (#5031; specs/session-cards/spec.md, family 4): every question to the person is
// drawn by Ask.tsx, the asks once in the transcript are under "Waiting for you", and an Ask's
// edge is the yellow of needs you (#5016).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { appCss } from "./appCss.mjs";

const read = (path) => readFileSync(new URL(`../src/${path}`, import.meta.url), "utf8");
const css = appCss();

test("every ask to the person is drawn as an Ask", () => {
  for (const file of ["views/Cards.tsx", "views/GuardedChange.tsx", "views/ArchiveCard.tsx", "views/DesktopControlPauseCard.tsx",
    "views/SecretUseCard.tsx", "views/chat/AppView.tsx", "views/chat/PolicyStopCard.tsx", "views/chat/Rows.tsx", "views/Chat.tsx"]) {
    assert.match(read(file), /<Ask /, `${file} draws an Ask`);
  }
});

test("the sandbox, policy and view asks are under Waiting for you, not in the transcript", () => {
  const chat = read("views/Chat.tsx");
  assert.match(chat, /<SandboxAsk /);
  assert.match(chat, /<PolicyStopAsk /);
  assert.match(chat, /<ViewAsk /);
  const view = read("views/chat/AppView.tsx");
  const row = view.slice(view.indexOf("export function AppView("), view.indexOf("export function ViewAsk("));
  assert.doesNotMatch(row, /answerShow|answerMessage/, "the view's row no longer asks");
  const policy = read("views/chat/PolicyStopCard.tsx");
  const record = policy.slice(policy.indexOf("export function PolicyStopCard("), policy.indexOf("export function canRaise("));
  assert.doesNotMatch(record, /askForMoreTitle/, "the record no longer offers Ask for More");
});

test("an Ask's edge and the label are yellow, and never filled", () => {
  assert.match(css, /\.card\.ask \{[^}]*border-left: 3px solid var\(--tint-attention\)/);
  assert.match(css, /\.waiting-label \{[^}]*color: var\(--tint-attention\)/);
  assert.doesNotMatch(css.match(/\.card\.ask \{[^}]*\}/)[0], /background/);
});
