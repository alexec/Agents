// Connect to Another… on the page this Mac serves (#4257): the code it takes, and the place it names,
// as the window's ConnectAnother.check and place.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/connectAnother.ts");

const key = "B" + "A".repeat(86);
const secret = "A".repeat(43);
const code = (kind, grant, url, name) => `agents-control:2:${kind}:${grant}:${key}:${secret}:${encodeURIComponent(url)}:-:${encodeURIComponent(name)}`;

test("a client code names its control plane by its address's host name", () => {
  const checked = c.checkConnectCode(`  ${code("c", "operator", "https://k3v9x0qa7b.cp.agentloops.dev", "Team")}  `);
  assert.equal(checked.place, "k3v9x0qa7b.cp.agentloops.dev");
  assert.equal(checked.url, "https://k3v9x0qa7b.cp.agentloops.dev");
  assert.equal(checked.code, code("c", "operator", "https://k3v9x0qa7b.cp.agentloops.dev", "Team"));
});

test("on an IP address or localhost, by the name it gives itself, with no link", () => {
  const checked = c.checkConnectCode(code("c", "operator", "http://127.0.0.1:8790", "Studio Mac"));
  assert.equal(checked.place, "Studio Mac");
  assert.equal(checked.url, undefined);
});

test("a machine code, or anything else, is refused with words that say which code to use", () => {
  assert.equal(c.checkConnectCode(code("h", "-", "https://x.example", "X")).problem, c.connectAnotherWords.machineCode);
  assert.equal(c.checkConnectCode("hello").problem, c.connectAnotherWords.notACode);
});

test("it says what happens before it does, and after", () => {
  assert.match(c.connectBefore("agentloops.dev"), /report to agentloops\.dev\. Your sessions stay on this Mac\..*The control plane on this Mac stops\.$/);
  assert.match(c.connectDone("agentloops.dev"), /now report to agentloops\.dev/);
});
