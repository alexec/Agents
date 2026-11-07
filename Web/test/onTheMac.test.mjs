// What only the Mac app does (#3425): with a Mac, a line sends the person there as before; with
// none, it says what the web page cannot do yet, or names the machine, never "on the Mac".
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const mac = await load("src/model/onTheMac.ts");
const connectors = await load("src/model/connectorSetup.ts");
const providers = await load("test/machineProviders.ts");
const hosted = await load("src/model/hostedMCP.ts");
const attachments = await load("src/model/attachments.ts");
const diff = await load("src/model/diff.ts");

const noMac = () => [
  mac.resourcesHint(false), mac.limitsHint(false), mac.terminalOutput(false),
  connectors.otherTrackers(true, false), connectors.otherTrackers(false, false), connectors.docs.addElsewhere(false),
  connectors.jira.tasksNote(false), connectors.codespacesElsewhere(false),
  providers.providerWords.footer(false), hosted.personalIntro(false),
  attachments.textAttachment(new Uint8Array([0xff]), "a.bin", "", false).refused,
  attachments.refusal({ block: { type: "resource", resource: { uri: "browser:x", text: "x" } } }, {}, "Codex", false),
];

test("with no Mac, no line sends the person to the Mac", () => {
  for (const line of noMac()) assert.doesNotMatch(line, /\bMac\b/, line);
  assert.equal(mac.limitsHint(false), "The web page cannot set limits yet.");
  assert.equal(connectors.codespacesElsewhere(false), "GitHub Codespaces: add it in Settings ▸ Machine providers, with Add Provider….");
  assert.match(hosted.personalIntro(false), /Edit them in ~\/\.agents\/mcp\.json on each machine\.$/);
  assert.equal(attachments.refusal({ block: { type: "resource", resource: { uri: "browser:x", text: "x" } } }, {}, "Codex", false),
    "Codex does not take file contents");
});

test("with a Mac, each line says what it said before", () => {
  assert.equal(mac.resourcesHint(true), "Declared on the Mac, in Settings ▸ Resources. Agents lease one whenever its description applies.");
  assert.equal(mac.limitsHint(true), "Limits are set on the Mac.");
  assert.equal(mac.terminalOutput(true), "Terminal output is shown in the Mac window.");
  assert.equal(connectors.otherTrackers(true, true), "Linear and other trackers: Add Connector on the Mac.");
  assert.equal(connectors.jira.tasksNote(true), "Connect Jira, then add its connector on the Mac.");
  assert.equal(connectors.codespacesElsewhere(true), "GitHub Codespaces: Set up on the Mac.");
  assert.match(providers.providerWords.footer(true), /are added in the Mac app\.$/);
  assert.match(hosted.personalIntro(true), /Edit them in the Mac's Settings ▸ Agent Configuration ▸ Connectors\.$/);
});

test("git missing names the folder's machine, or the Mac", () => {
  const git = { unavailable: { gitNotInstalled: {} } };
  assert.equal(diff.unavailableNote(git), "Git is not installed on the Mac.");
  assert.equal(diff.unavailableNote(git, "build-box"), "Git is not installed on build-box.");
});
