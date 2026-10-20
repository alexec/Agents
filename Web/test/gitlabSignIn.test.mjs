// Connect GitLab (#1630): the words of an access-token connection, and where the person makes
// a token, on gitlab.com or a self-managed GitLab.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/connectorSetup.ts");
// Wire dates are seconds since 2001-01-01.
const wire = (iso) => (Date.parse(iso) - Date.UTC(2001, 0, 1)) / 1000;

test("a token's row says its GitLab and when it ends", () => {
  const conn = { provider: "gitlab", login: "agentstest", state: "connected", connectedAt: 0,
    workspace: "gitlab.example.com", expiresAt: wire("2027-10-19T00:00:00Z") };
  assert.equal(c.connectionNote(conn, new Date("2026-10-20T00:00:00Z")), "gitlab.example.com · Access token · ends 19 Oct 2027");
  assert.equal(c.connectionNote({ ...conn, state: "signInAgain" }), "The access token ended: connect again with a new one");
  assert.equal(c.connectionNote({ provider: "gitlab", state: "connected", connectedAt: 0 }), "OAuth · renews by itself");
});

test("Make a Token opens the right GitLab with the api scope", () => {
  assert.equal(c.newGitLabTokenURL(""), "https://gitlab.com/-/user_settings/personal_access_tokens?name=Agents&scopes=api");
  assert.equal(c.newGitLabTokenURL("gitlab.example.com/api/v4/"),
    "https://gitlab.example.com/-/user_settings/personal_access_tokens?name=Agents&scopes=api");
});

test("GitLab is the third provider, and its device page is gitlab.com", () => {
  assert.deepEqual(c.providers, ["github", "linear", "gitlab"]);
  assert.equal(c.sheetStatus({ provider: "gitlab", status: "waiting", grant: "deviceCode" }),
    "Waiting for gitlab.com… Type the code there, then approve.");
});
