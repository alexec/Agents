// GitHub's token (#3857): a GitHub connection's row says which kind of token it uses, the App's
// user token (the default) or the person's own, as the Mac's ConnectorSetupWords.GitHubTokens.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/connectorSetup.ts");

test("a GitHub connection by the App says the App's user token", () => {
  const conn = { provider: "github", login: "octocat", state: "connected", connectedAt: 0,
    installURL: "https://github.com/apps/agents-loops/installations/new" };
  assert.equal(c.connectionNote(conn), "App user token · renews by itself · posts show the App");
});

test("a GitHub personal access token says so, and when it ends", () => {
  const conn = { provider: "github", login: "octocat", state: "connected", connectedAt: 0, byToken: true };
  assert.equal(c.connectionNote(conn), "Personal access token · posts show no App");
  // 2027-02-01T16:00:00Z, as seconds after 2001-01-01 (the wire's date).
  const ends = Date.UTC(2027, 1, 1, 16) / 1000 - 978307200;
  assert.equal(c.connectionNote({ ...conn, expiresAt: ends }, new Date(Date.UTC(2026, 10, 7))),
    "Personal access token · posts show no App · ends 1 Feb 2027");
});

test("a GitHub connection the host could not renew says to sign in again", () => {
  assert.equal(c.connectionNote({ provider: "github", state: "signInAgain", connectedAt: 0 }),
    "GitHub refused the renewal: sign in again");
});
