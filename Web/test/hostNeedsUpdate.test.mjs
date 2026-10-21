// A feature left out because the host is too old says so (#1866): the line in a hidden
// section's place, or the control greyed with it as its title, as the window and the Remote.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL(`../src/${path}`, import.meta.url), "utf8");

test("host too old: the connector set-up and Your Connections say so in their place", () => {
  assert.match(read("views/MCPServers.tsx"), /Capability\.connectorsSetup1\)\s*\?[\s\S]*?:\s*<p class="hint">\{hostNeedsUpdate\}<\/p>/);
  assert.match(read("views/Activity.tsx"), /Capability\.connections1\)\s*\?[\s\S]*?:\s*<p class="hint">\{hostNeedsUpdate\}<\/p>/);
});

test("host too old: a file's problems and completion say so, with no call", () => {
  const editor = read("views/files/SourceEditor.tsx");
  assert.match(editor, /problems\.value = \{ diagnostics: \[\], reason: hostNeedsUpdate \}/);
  assert.match(editor, /Capability\.filesComplete1\)\) \{ say\(hostNeedsUpdate\); return; \}/);
});

test("host too old: Edit on a queued prompt and Branch from Here stay, greyed, saying why", () => {
  const chat = read("views/Chat.tsx");
  assert.match(chat, /title=\{store\.has\(host, Capability\.agentsEditQueued1\) \? "[^"]+" : hostNeedsUpdate\}/);
  assert.match(chat, /disabled=\{[^}]*!store\.has\(host, Capability\.agentsEditQueued1\)\}/);
  assert.match(chat, /branchNeedsUpdate: !!agent && agent\.state !== "archived" && !store\.has\(host, Capability\.chatBranch1\)/);
  assert.match(chat, /branchNeedsUpdate=\{agent\.state !== "archived" && !store\.has\(host, Capability\.chatBranch1\)\}/);
  assert.match(read("views/chat/Rows.tsx"), /<button class="steps-control" title=\{hostNeedsUpdate\} disabled>Branch from Here<\/button>/);
  assert.match(read("views/chat/PromptList.tsx"), /<button role="menuitem" title=\{hostNeedsUpdate\} disabled>Branch from Here<\/button>/);
});
