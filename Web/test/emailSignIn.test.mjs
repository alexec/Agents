// Connect Email (#1780): the words of an email connection, the request the sheet sends, and
// Email only on a host with connections.email/1.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/connectorSetup.ts");

test("an email row says its IMAP server and the app password", () => {
  const conn = { provider: "email", login: "agents@example.com", workspace: "imap.fastmail.com", state: "connected", connectedAt: 0 };
  assert.equal(c.connectionTitle(conn), "Email · agents@example.com");
  assert.equal(c.connectionNote(conn), "imap.fastmail.com · App password");
});

test("Email has the Mac's words", () => {
  assert.equal(c.name("email"), "Email");
  assert.equal(c.letters("email"), "EM");
  assert.equal(c.email.sheetFoot, "The app password is kept by the machine, never in a log.");
  assert.equal(c.site("email"), "");
  assert.equal(c.notConnectedNote("email"), "One mailbox for agents: they wait for mail, such as a sign-up code, and read it.");
  assert.equal(c.continueButtonFor("email"), "Connect");
  assert.equal(c.sheetSubtitleFor("email"), c.email.subtitle);
  assert.deepEqual(c.abilitiesFor("email"), c.email.abilities);
  assert.equal(c.sheetChooseFor("email"), c.email.choose);
  assert.match(c.disconnectNoteFor("email"), /EMAIL_PASSWORD/);
  assert.equal(c.email.failed, "The mail server did not take the sign-in.");
});

test("the request has all three fields, or none", () => {
  assert.deepEqual(c.emailRequest(" imap.fastmail.com ", " agents@example.com ", " secret "),
    { server: "imap.fastmail.com", user: "agents@example.com", password: " secret " });
  assert.equal(c.emailRequest("", "agents@example.com", "secret"), undefined);
  assert.equal(c.emailRequest("imap.fastmail.com", " ", "secret"), undefined);
  assert.equal(c.emailRequest("imap.fastmail.com", "agents@example.com", ""), undefined);
});

test("A host older than #3824: Email comes before Atlassian, and only with connections.email/1; no Forgejo or Bitbucket", () => {
  assert.deepEqual(c.providersFor(true), ["github", "linear", "gitlab", "email", "atlassian"]);
  assert.deepEqual(c.providersFor(false), ["github", "linear", "gitlab", "atlassian"]);
});

test("Connect… offers only what the host says it connects, in the page's order, less names the page does not know (#3824)", () => {
  assert.deepEqual(c.providersFor(false, ["bitbucket", "github", "email", "forgejo", "linear", "gitlab", "atlassian"]),
    ["github", "linear", "gitlab", "email", "atlassian", "forgejo", "bitbucket"]);
  assert.deepEqual(c.providersFor(true, ["github", "azuredevops"]), ["github"]);
});
