// Connect Bitbucket (#3785): the words of a Bitbucket connection, the token request, and a
// Bitbucket folder's set-up, as the Mac's ConnectorSetupWords.Bitbucket.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/connectorSetup.ts");

test("a Bitbucket connection's row says bitbucket.org and that it is a token", () => {
  const conn = { provider: "bitbucket", login: "agentstest", state: "connected", connectedAt: 0, workspace: "bitbucket.org" };
  assert.equal(c.connectionTitle(conn), "Bitbucket · agentstest");
  assert.equal(c.connectionNote(conn), "bitbucket.org · Token");
});

test("the request sends the email only for an Atlassian API token", () => {
  const sheet = c.tokenSheet("bitbucket");
  assert.equal(sheet.fieldLabel, "Atlassian email");
  assert.deepEqual(c.tokenRequest(sheet, " me@example.com ", " t "), { provider: "bitbucket", user: "me@example.com", token: "t" });
  assert.deepEqual(c.tokenRequest(sheet, "", "t"), { provider: "bitbucket", token: "t" });
  assert.equal(c.tokenRequest(sheet, "me@example.com", " "), undefined);
});

test("Bitbucket is a provider to connect, with a mark and a name", () => {
  assert.ok(c.providers.includes("bitbucket"));
  assert.equal(c.connectButtonFor("bitbucket"), "Connect Bitbucket…");
  assert.equal(c.letters("bitbucket"), "BB");
  assert.match(c.disconnectNoteFor("bitbucket"), /^Disconnect deletes the machine's token\. Every folder's Bitbucket slots wait for a connection again\. /);
});

test("a Bitbucket folder's set-up says Bitbucket, pull requests and checks", () => {
  const setup = { folder: "/p", repository: "team/app", forge: "bitbucket", site: "bitbucket.org",
    repositoryURL: "https://bitbucket.org/team/app", slots: [], events: { state: "off", names: [], workflows: [] }, done: 1 };
  assert.equal(c.connectTitleFor("bitbucket"), "Connect Bitbucket once: issues, pull requests and checks.");
  assert.equal(c.connectNoteFor("bitbucket"), "Your connection, for every folder. It reaches what your Bitbucket account can see.");
  assert.equal(c.grantButton(setup), "Open on bitbucket.org");
  assert.equal(c.grantURL(setup), "https://bitbucket.org/team/app");
  const ci = { slot: "ci", choice: "Bitbucket checks", state: "read" };
  assert.equal(c.line(ci, "App", "team/app", false, "bitbucket"), "No checks yet on team/app's default branch.");
});
