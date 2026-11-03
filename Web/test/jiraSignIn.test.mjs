// Connect Jira (#3304): one Atlassian sign-in for Jira and Confluence, the Mac's words, the
// token request the sheet sends, and the newest issue that proves the connection.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/connectorSetup.ts");
const dates = await load("src/protocol/dates.ts");

test("the Atlassian connection has the Mac's words, and the sheet says Jira", () => {
  assert.equal(c.name("atlassian"), "Atlassian");
  assert.equal(c.letters("atlassian"), "JI");
  assert.equal(c.site("atlassian"), "atlassian.com");
  assert.equal(c.connectButtonFor("atlassian"), "Connect Jira…");
  assert.equal(c.connectJira, "Connect Jira…");
  assert.equal(c.continueButtonFor("atlassian"), "Continue on atlassian.com");
  assert.equal(c.sheetSubtitleFor("atlassian"), c.jira.subtitle);
  assert.deepEqual(c.abilitiesFor("atlassian"), c.jira.abilities);
  assert.equal(c.sheetChooseFor("atlassian"), c.jira.choose);
  assert.match(c.disconnectNoteFor("atlassian"), /JIRA_API_TOKEN/);
  assert.equal(c.notConnectedNote("atlassian"), "Jira issues and Confluence docs, with one sign-in.");
});

test("waiting on atlassian.com says atlassian.com, not linear.app", () => {
  const flow = { flowID: "f", provider: "atlassian", status: "waiting", grant: "authorizationCode", verificationURL: "x", expiresAt: 0 };
  assert.equal(c.sheetStatus(flow), c.jira.waiting);
  assert.equal(c.sheetStatus({ ...flow, provider: "linear" }), c.linear.waiting);
});

test("the token request has the site and the token, and the email only when given", () => {
  assert.deepEqual(c.jiraTokenRequest(" acme.atlassian.net ", " a@b.c ", " tok "),
    { provider: "atlassian", url: "acme.atlassian.net", user: "a@b.c", token: "tok" });
  assert.deepEqual(c.jiraTokenRequest("jira.acme.com", " ", "pat"), { provider: "atlassian", url: "jira.acme.com", token: "pat" });
  assert.equal(c.jiraTokenRequest("", "a@b.c", "tok"), undefined);
  assert.equal(c.jiraTokenRequest("acme.atlassian.net", "a@b.c", " "), undefined);
});

test("the end of the sheet says where, as whom, and the newest issue", () => {
  const now = new Date("2026-11-02T12:00:00Z");
  const conn = { provider: "atlassian", login: "Alex", workspace: "Acme", state: "connected", connectedAt: 0,
    newest: { title: "ACME-7 Fix the walk", at: dates.toWireDate(new Date(now.getTime() - 2 * 3600_000)) } };
  assert.equal(c.jiraConnected(conn), "Connected to Acme as Alex.");
  assert.equal(c.connectionNote(conn), "Acme · OAuth · renews by itself");
  assert.equal(c.connectionNote({ ...conn, byToken: true }), "Acme · API token");
  assert.equal(c.jiraProof(conn, now), "Newest issue: ACME-7 Fix the walk 2 hours ago");
  assert.equal(c.jiraProof({ ...conn, newest: undefined }), "No issues read yet: the site has none, or the token cannot see them.");
});
