// The Sessions list on New Session (#3716): a conversation in another tool's worktree of the
// folder says which, and the page asks and picks up with sessions/list and sessions/adopt.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { load } from "./load.mjs";

const { sessionPlace } = await load("src/model/runtimeSessions.ts");

test("a conversation in the folder has no place; one in a worktree is named by it", () => {
  assert.equal(sessionPlace({ sessionID: "a", cwd: "file:///code/app/" }, "file:///code/app"), undefined);
  assert.equal(sessionPlace({ sessionID: "b", cwd: "file:///Users/me/conductor/workspaces/app/oslo%20two" }, "file:///code/app"), "oslo two");
});

test("New Session opens the list beside the runtime, not on Auto", () => {
  const view = readFileSync(new URL("../src/views/NewAgent.tsx", import.meta.url), "utf8");
  assert.match(view, /aria-label="Sessions"\s+disabled=\{down \|\| !chosenRuntime \|\| isAuto\}/);
  assert.match(view, /<SessionsDialog store=\{store\} host=\{host\} folder=\{folder\}/);
  const store = readFileSync(new URL("../src/model/store.ts", import.meta.url), "utf8");
  assert.match(store, /this\.link\.call\("sessions\/list"/);
  assert.match(store, /this\.link\.call\("sessions\/adopt"/);
});
