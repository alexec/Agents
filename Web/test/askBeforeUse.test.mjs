// Ask before use (#4016): the words on the Secrets page, For One Session and the ask card, as the
// window's and the Remote's AskBeforeUseWords say them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const a = await load("src/model/askBeforeUse.ts");

test("ask before use: says what on and off give an agent", () => {
  assert.equal(a.askBeforeUseWords.toggle, "Ask before use");
  assert.equal(a.askBeforeUseHint(true), "Only fill_secret, set_ci_secret and HTTP MCP servers can use it. It is not in $NAME or in a file.");
  assert.equal(a.askBeforeUseHint(false), "Every session on the machine can read it, as $NAME and from a file.");
  assert.equal(a.needsApprovalField, "needsApproval");
});
