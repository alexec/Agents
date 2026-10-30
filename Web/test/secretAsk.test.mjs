// An agent's ask_secret (#2885): the words under the masked field, as the window's and the
// Remote's SecretAskCard say them, and the link to where the secret is got.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const s = await load("src/model/secretAsk.ts");

test("secret ask: says where it goes, and that the agent never sees it", () => {
  assert.equal(s.keeping({ name: "OPENAI_API_KEY", isSet: false }, "your Mac"),
    "Saved to your secrets on your Mac. The agent gets its name, never the value.");
  assert.equal(s.keeping({ name: "GITLAB_TOKEN", isSet: true }, "devbox"),
    "Saved to your secrets on devbox. It replaces the one saved there. The agent gets its name, never the value.");
});

test("secret ask: a link only to a web page", () => {
  assert.equal(s.getIt("https://platform.openai.com/api-keys"), "Get it at platform.openai.com");
  assert.equal(s.getIt("javascript:alert(1)"), null);
  assert.equal(s.getIt("not a link"), null);
  assert.equal(s.getIt(undefined), null);
  assert.equal(s.secretField, "value");
});
