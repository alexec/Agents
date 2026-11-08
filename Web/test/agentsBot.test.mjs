// The person's agents' bot (#3858): its line under the GitHub row, the Mac's words, and the
// hand-back page's message for the setup under way only.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/connectorSetup.ts");

test("the bot's line says where it is installed", () => {
  assert.equal(c.botNote({ made: false }), c.botWords.notMade);
  const bot = { made: true, name: "alexec-agents[bot]", installations: [{ account: "alexec", all: false }, { account: "scratch-org", all: true }] };
  assert.equal(c.botNote(bot), "alexec-agents[bot], on alexec (chosen repositories), scratch-org (all repositories).");
  assert.match(c.botNote({ ...bot, installations: [] }), /not installed yet/);
  assert.match(c.botNote({ made: true, name: "x[bot]" }), /could not be asked/);
});

test("the bot's key line says which machines have it, as the Mac's does", () => {
  assert.equal(c.botKeyOn({ made: false }), undefined);
  assert.equal(c.botKeyOn({ made: true }), "Its key is on this machine only.");
  const keyOn = [{ name: "mac-mini", here: true, has: true }, { name: "devbox", has: true }, { name: "laptop", has: false }];
  assert.equal(c.botKeyOn({ made: true, keyOn }), "Its key is on mac-mini (here) and devbox. laptop gets it when it is online.");
  assert.equal(
    c.botKeyOn({ made: true, keyOn: [...keyOn, { name: "pi", has: false }] }),
    "Its key is on mac-mini (here) and devbox. laptop and pi get it when they are online.",
  );
});

test("the hand-back page's message counts only for the setup's own state", () => {
  const ok = { origin: "https://oauth.agentloops.dev", data: { type: "agents-oauth-callback", code: "c0de", state: "ab.cd" } };
  assert.deepEqual(c.botCallback(ok, "ab.cd"), { state: "ab.cd", code: "c0de" });
  assert.equal(c.botCallback(ok, "other"), undefined);
  assert.equal(c.botCallback({ ...ok, origin: "https://evil.example" }, "ab.cd"), undefined);
});
