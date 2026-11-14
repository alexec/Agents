// Connect Azure DevOps (#3802): the words of an Azure DevOps connection, the one token sheet's
// fields and request, an Azure DevOps folder's set-up, and a forge or connection this page does
// not know, as the Mac's ConnectorSetupWords.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const c = await load("src/model/connectorSetup.ts");

test("an Azure DevOps connection's row says its organization and that it is a personal access token", () => {
  const conn = { provider: "azuredevops", login: "Agents Test", state: "connected", connectedAt: 0, workspace: "dev.azure.com/acme", byToken: true };
  assert.equal(c.connectionTitle(conn), "Azure DevOps · Agents Test");
  assert.equal(c.connectionNote(conn), "dev.azure.com/acme · Personal access token");
  assert.equal(c.tokenSheet("azuredevops").again(conn), "dev.azure.com/acme");
});

test("an Entra sign-in's row renews by itself, and Connect Again opens on the Entra way (#3921)", () => {
  const conn = { provider: "azuredevops", login: "Agents Test", state: "connected", connectedAt: 0, workspace: "dev.azure.com/acme" };
  assert.equal(c.connectionNote(conn), "dev.azure.com/acme · Microsoft Entra · renews by itself");
  assert.equal(c.azureDevOps.againWithEntra(conn), true);
  assert.equal(c.azureDevOps.againWithEntra({ ...conn, byToken: true }), false);
  assert.equal(c.connectionNote({ ...conn, state: "signInAgain" }), "Azure DevOps refused the renewal: sign in again");
  const waiting = { flowID: "f", provider: "azuredevops", status: "waiting", grant: "deviceCode", verificationURL: "https://microsoft.com/devicelogin", expiresAt: 0 };
  assert.equal(c.sheetStatus(waiting), "Waiting for Microsoft's sign-in page… Type the code there, then approve.");
});

test("Make a Token opens the organization's tokens page", () => {
  for (const [typed, page] of [["", "https://dev.azure.com/"], ["acme", "https://dev.azure.com/acme/_usersSettings/tokens"],
    ["https://dev.azure.com/acme/Web/_git/app", "https://dev.azure.com/acme/_usersSettings/tokens"],
    ["acme.visualstudio.com", "https://dev.azure.com/acme/_usersSettings/tokens"],
    ["tfs.example.com/tfs/Main/", "https://tfs.example.com/tfs/Main/_usersSettings/tokens"]]) {
    assert.equal(c.newAzureDevOpsTokenURL(typed), page, typed);
  }
});

test("the one token sheet: each provider's field beside the token, sent as url or user", () => {
  const ado = c.tokenSheet("azuredevops");
  assert.equal(ado.fieldLabel, "Organization");
  assert.deepEqual(c.tokenRequest(ado, " dev.azure.com/acme ", " t "), { provider: "azuredevops", url: "dev.azure.com/acme", token: "t" });
  const forgejo = c.tokenSheet("forgejo");
  assert.deepEqual(c.tokenRequest(forgejo, "", "t"), { provider: "forgejo", token: "t" });
  assert.equal(forgejo.newTokenURL(""), "https://codeberg.org/user/settings/applications");
  for (const p of ["github", "linear", "gitlab", "email", "atlassian"]) assert.equal(c.tokenSheet(p), undefined, p);
});

test("Azure DevOps is a provider to connect, with a mark and a name", () => {
  assert.ok(c.providers.includes("azuredevops"));
  assert.deepEqual(c.providersFor(true, ["azuredevops", "github", "sourcehut"]), ["github", "azuredevops"]);
  assert.equal(c.connectButtonFor("azuredevops"), "Connect Azure DevOps…");
  assert.equal(c.letters("azuredevops"), "AZ");
  assert.match(c.disconnectNoteFor("azuredevops"), /^Disconnect deletes the machine's token\. Every folder's Azure DevOps slots wait for a connection again\. /);
});

test("an Azure DevOps folder's set-up says work items, pull requests and builds", () => {
  const setup = { folder: "/p", repository: "acme/Web/app", forge: "azuredevops", site: "dev.azure.com",
    repositoryURL: "https://dev.azure.com/acme/Web/_git/app", slots: [], events: { state: "off", names: [], workflows: [] }, done: 1 };
  assert.equal(c.connectTitleFor("azuredevops"), "Connect Azure DevOps once: work items, pull requests and pipelines.");
  assert.equal(c.grantButton(setup), "Open on dev.azure.com");
  assert.equal(c.grantURL(setup), "https://dev.azure.com/acme/Web/_git/app");
  assert.equal(c.line({ slot: "ci", choice: "Azure Pipelines", state: "read" }, "App", "acme/Web/app", false, "azuredevops"), "No builds yet in acme/Web/app.");
  assert.equal(c.line({ slot: "tasks", choice: "Azure Boards work items", state: "read" }, "App", "acme/Web/app", false, "azuredevops"),
    "No work items yet in acme/Web/app's project.");
  assert.equal(c.unknownForgeOf(setup), undefined);
});

test("a newer host's forge says to update Agents, and its connections are left out", () => {
  const setup = { folder: "/p", repository: "a/b", forge: "sourcehut", site: "git.sr.ht", slots: [], events: { state: "off", names: [], workflows: [] }, done: 0 };
  assert.equal(c.unknownForgeOf(setup), "sourcehut");
  assert.match(c.unknownForge(setup), /^git\.sr\.ht is on a forge this version of Agent Loops can't connect \(sourcehut\)\. Update Agent Loops/);
  const list = [{ provider: "sourcehut", state: "connected", connectedAt: 0 }, { provider: "github", state: "connected", connectedAt: 0 }];
  assert.deepEqual(c.knownConnections(list).map((x) => x.provider), ["github"]);
});
