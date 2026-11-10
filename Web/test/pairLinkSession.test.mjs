// Opened with a code in the address that isn't one (#4129): the page shows the pairing form and
// says so, rather than staying on "Connecting…".
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

delete globalThis.BroadcastChannel;
const { Session, pairingWords } = await load("src/session.ts");
const w = await load("test/wire.ts");
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test("a code from the address that doesn't parse leaves the pairing form, with its words", async () => {
  const session = new Session(new w.MemoryKeyStore(), "http://localhost:8792", () => {
    throw new Error("nothing is dialled for a code that isn't one");
  }, new w.MemoryPendingStore());
  session.start("agents-control:2:c:-:AAAA:BBBB:https://x:8792:-:Mac");
  for (let i = 0; i < 50 && session.state.value.kind === "loading"; i++) await wait(10);
  assert.equal(session.state.value.kind, "unpaired");
  assert.equal(session.pairingError.value, pairingWords.notACode);
});
