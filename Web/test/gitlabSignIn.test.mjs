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
  assert.equal(c.connectionNote(conn, new Date("2026-10-20T00:00:00Z")), "gitlab.example.com · Access token · ends 18 Oct 2027");
  assert.equal(c.connectionNote({ ...conn, state: "signInAgain" }), "The access token ended: connect again with a new one");
  assert.equal(c.connectionNote({ provider: "gitlab", state: "connected", connectedAt: 0 }), "OAuth · renews by itself");
});

test("Connect Again on an ended GitLab connection opens the way it was made (#1865)", () => {
  const ended = { provider: "gitlab", state: "signInAgain", connectedAt: 0, workspace: "gitlab.example.com", expiresAt: 0 };
  assert.deepEqual(c.gitlabAgain(ended), { withToken: true, address: "https://gitlab.example.com" });
  assert.deepEqual(c.gitlabAgain({ ...ended, workspace: undefined }), { withToken: true, address: "https://gitlab.com" });
  assert.deepEqual(c.gitlabAgain({ ...ended, workspace: undefined, expiresAt: undefined }), { withToken: false, address: "" });
});

test("Make a Token opens the right GitLab with the api scope", () => {
  assert.equal(c.newGitLabTokenURL(""), "https://gitlab.com/-/user_settings/personal_access_tokens?name=Agents&scopes=api");
  assert.equal(c.newGitLabTokenURL("gitlab.example.com/api/v4/"),
    "https://gitlab.example.com/-/user_settings/personal_access_tokens?name=Agents&scopes=api");
});

test("GitLab is the third provider, and its device page is gitlab.com", () => {
  assert.deepEqual(c.providers.slice(0, 3), ["github", "linear", "gitlab"]);
  assert.equal(c.sheetStatus({ provider: "gitlab", status: "waiting", grant: "deviceCode" }),
    "Waiting for gitlab.com… Type the code there, then approve.");
});

// Connect your tools with GitLab (#1632): the set-up's words follow its forge.
test("a GitLab folder's set-up says GitLab, merge requests and pipelines", () => {
  const setup = { folder: "/p", repository: "group/app", forge: "gitlab", site: "gitlab.example.com",
    repositoryURL: "https://gitlab.example.com/group/app", slots: [], events: { state: "off", names: [], workflows: [] }, done: 1 };
  assert.equal(c.intro("App", setup.repository, setup.site), "What agents in App can reach. Repository gitlab.example.com/group/app, from its git remote.");
  assert.equal(c.connectButtonFor(c.forgeOf(setup)), "Connect GitLab…");
  assert.equal(c.grantButton(setup), "Open on gitlab.example.com");
  assert.equal(c.grantURL(setup), "https://gitlab.example.com/group/app");
  const ci = { slot: "ci", choice: "GitLab pipelines", state: "read" };
  assert.equal(c.line(ci, "App", "group/app", false, "gitlab"), "No pipelines yet in group/app.");
  assert.equal(c.eventsLead(setup.events, "gitlab"), "Off. They go on once a slot has read from GitLab.");
  assert.equal(c.forgeOf({ ...setup, forge: undefined }), "github");
});

test("Disconnect GitLab says every folder's GitLab slots wait again, as the Mac does (#1868)", () => {
  assert.match(c.disconnectNoteFor("gitlab"), /^Disconnect deletes the machine's token\. Every folder's GitLab slots wait for a connection again\. /);
});
