// A Mac's git access lent to a host (#1122): the ask a host's row carries, asked once on this
// page, the lends with Stop Lending, and the words, as the window says them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const { firstAsk, waiting, lends, gitLendWords, askID } = await load("src/model/gitLending.ts");

const mac = { id: "mac1", name: "Alex's Mac", platform: "macOS arm64", version: "1", state: "online", reach: "dialOut" };
const box = (more) => ({ id: "box", name: "devbox", platform: "Linux arm64", version: "1", state: "online", reach: "dialOut", ...more });

test("a host's ask names it, the git server and the Mac", () => {
  const rows = [mac, box({ gitAsks: [{ server: "github.com", from: "mac1" }] })];
  const ask = firstAsk(rows, new Set());
  assert.deepEqual(ask, { host: "box", hostName: "devbox", server: "github.com", from: "mac1", lenderName: "Alex's Mac" });
  assert.equal(gitLendWords.title(ask), "Let devbox use Alex's Mac’s git access for github.com?");
  assert.match(gitLendWords.message(ask), /Nothing is kept on devbox/);
  // Answered here: not asked again while it waits, and forgotten once it isn't waiting.
  assert.equal(firstAsk(rows, new Set([askID("box", "github.com")])), null);
  assert.deepEqual([...waiting(rows)], ["box github.com"]);
  assert.deepEqual([...waiting([mac, box()])], []);
});

test("every lend is listed, server by server", () => {
  const rows = [mac, box({ gitFrom: { "gitlab.com": "mac1", "github.com": "mac1" } })];
  assert.deepEqual(lends(rows).map((l) => `${l.hostName} ${l.server} ${l.lenderName}`),
    ["devbox github.com Alex's Mac", "devbox gitlab.com Alex's Mac"]);
  assert.deepEqual(lends([mac, box()]), []);
});
