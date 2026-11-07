// Connect Forgejo (#3752): the words of a Forgejo connection, where the person makes a token,
// and a Forgejo folder's set-up, as the Mac's ConnectorSetupWords.Forgejo.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/connectorSetup.ts");

test("a Forgejo connection's row says its host and that it is an access token", () => {
  const conn = { provider: "forgejo", login: "agentstest", state: "connected", connectedAt: 0, workspace: "codeberg.org" };
  assert.equal(c.connectionTitle(conn), "Forgejo · agentstest");
  assert.equal(c.connectionNote(conn), "codeberg.org · Access token");
  assert.equal(c.forgejoAgain(conn), "https://codeberg.org");
  assert.equal(c.forgejoAgain({ ...conn, workspace: undefined }), "");
});

test("Make a Token opens the Forgejo's applications page", () => {
  assert.equal(c.newForgejoTokenURL(""), "https://codeberg.org/user/settings/applications");
  assert.equal(c.newForgejoTokenURL("git.example.com/api/v1/"), "https://git.example.com/user/settings/applications");
  assert.equal(c.newForgejoTokenURL("https://example.com/git/"), "https://example.com/git/user/settings/applications");
});

test("Forgejo is a provider to connect, with a mark and a name", () => {
  assert.ok(c.providers.includes("forgejo"));
  assert.equal(c.connectButtonFor("forgejo"), "Connect Forgejo…");
  assert.equal(c.letters("forgejo"), "FJ");
  assert.match(c.disconnectNoteFor("forgejo"), /^Disconnect deletes the machine's token\. Every folder's Forgejo slots wait for a connection again\. /);
});

test("a Forgejo folder's set-up says Forgejo, pull requests and checks", () => {
  const setup = { folder: "/p", repository: "team/app", forge: "forgejo", site: "git.example.com",
    repositoryURL: "https://git.example.com/team/app", slots: [], events: { state: "off", names: [], workflows: [] }, done: 1 };
  assert.equal(c.connectTitleFor("forgejo"), "Connect Forgejo once: issues, pull requests and checks.");
  assert.equal(c.connectNoteFor("forgejo"), "Your connection, for every folder. It reaches what your Forgejo account can see.");
  assert.equal(c.grantButton(setup), "Open on git.example.com");
  assert.equal(c.grantURL(setup), "https://git.example.com/team/app");
  const ci = { slot: "ci", choice: "Forgejo checks", state: "read" };
  assert.equal(c.line(ci, "App", "team/app", false, "forgejo"), "No checks yet on team/app's default branch.");
  const review = { slot: "codeReview", choice: "Forgejo pull requests", state: "notConnected" };
  assert.equal(c.line(review, "App", "team/app", false, "forgejo"), "Agents open pull requests and answer reviews. Comes with the Forgejo connection.");
});
