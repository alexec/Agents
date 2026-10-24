// The order runtimes are listed in (#154), the same rule as RuntimeCatalog.sortedByName.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const r = await load("src/model/runtimes.ts");
const status = (id, name, available = true) => ({
  runtime: { id, name }, availability: available ? { available: { path: "/x", supportsResume: true } } : { missing: { lookedIn: [] } },
});

test("runtimes: alphabetical by the name shown, not the id or the order sent", () => {
  const sent = [status("claude", "Claude"), status("grok", "Grok"), status("copilot", "Copilot"),
    status("cursor", "Cursor"), status("codex", "Codex"), status("gemini", "Gemini"),
    status("antigravity", "Antigravity"), status("opencode", "OpenCode")];
  assert.deepEqual(r.sortedRuntimes(sent).map((s) => s.runtime.name),
    ["Antigravity", "Claude", "Codex", "Copilot", "Cursor", "Gemini", "Grok", "OpenCode"]);
});

test("runtimes: case does not count, and the id breaks a tie", () => {
  const sent = [status("b", "beta"), status("z", "Alpha"), status("a", "alpha")];
  assert.deepEqual(r.sortedRuntimes(sent).map((s) => s.runtime.id), ["a", "z", "b"]);
});

for (const { name, input, expected } of (await import("./fixtures.mjs")).cases("runtimes/reasons.json")) {
  test(`runtimes: why it cannot start, ${name}`, () => assert.equal(r.unavailableReason(input), expected));
}

test("runtimes: a chooser's runs are available, out and cannot start", () => {
  const out = { ...status("grok", "Grok"), isOut: true };
  const got = r.runtimeRuns([status("claude", "Claude"), out, status("codex", "Codex", false)]);
  assert.deepEqual([got.available, got.out, got.cannot].map((run) => run.map((s) => s.runtime.id)), [["claude"], ["grok"], ["codex"]]);
});

for (const { name, input, expected } of (await import("./fixtures.mjs")).cases("runtimes/new-session.json")) {
  test(`runtimes: a new session opens on, ${name}`, () => assert.equal(r.newSessionRuntime(input.lastUsed ?? undefined, input.kept ?? undefined, input.available) ?? null, expected));
}

test("runtimes: an empty list says so when nothing on this Mac can start (#257)", () => {
  assert.equal(r.noAgentRuntime(undefined), false, "not yet listed is not none");
  assert.equal(r.noAgentRuntime([]), true);
  assert.equal(r.noAgentRuntime([status("claude", "Claude", false)]), true);
  assert.equal(r.noAgentRuntime([status("claude", "Claude"), status("codex", "Codex", false)]), false, "one that can start is enough");
  const missing = status("goose", "Goose", false);
  missing.runtime.installPage = "https://example.com/goose";
  assert.deepEqual(r.emptyListRuntimeLine(missing), { line: "Not on this Mac", failed: false, page: "https://example.com/goose" });
  missing.runtime.install = { toolset: { runtimeID: "goose" } };
  assert.deepEqual(r.emptyListRuntimeLine(missing), { line: "Not on this Mac", failed: false }, "Install stays on the Mac");
  const failed = { ...status("codex", "Codex", false), availability: { installFailed: { reason: "disk full" } }, runtime: { ...status("codex", "Codex").runtime, installPage: "https://example.com/codex", install: { toolset: { runtimeID: "codex" } } } };
  assert.deepEqual(r.emptyListRuntimeLine(failed), { line: "disk full", failed: true, page: "https://example.com/codex" });
  const signing = { ...status("claude", "Claude", false), availability: { needsSignIn: { authMethods: [] } } };
  assert.equal(r.emptyListRuntimeLine(signing).line, "Signed out.");
  const installing = { ...status("gemini", "Gemini", false), availability: { installing: { progress: "Fetching" } } };
  assert.deepEqual(r.emptyListRuntimeLine(installing), { line: "Fetching…", failed: false });
});

test("runtimes: a new session stays on the runtime it opened with (#291)", () => {
  assert.equal(r.formRuntime("codex", undefined, ["claude", "codex"], "claude", "claude"), "codex", "a later listing does not move it");
  assert.equal(r.formRuntime("codex", "claude", ["claude", "codex"], "codex", undefined), "claude", "a pick here wins");
  assert.equal(r.formRuntime("codex", undefined, ["claude"], "claude", undefined), "claude", "one that can no longer start falls through");
  assert.equal(r.formRuntime(undefined, undefined, ["codex"], undefined, undefined), "codex");
  assert.equal(r.formRuntime(undefined, undefined, ["codex", "claude"], undefined, undefined), "codex");
});

test("runtimes: the Runtimes row counts working out of installed (#379)", () => {
  const signedOut = { runtime: { id: "codex", name: "Codex" }, availability: { needsSignIn: { authMethods: [] } } };
  const installing = { runtime: { id: "cursor", name: "Cursor" }, availability: { installing: {} } };
  assert.equal(r.runtimeTally([]), undefined, "not yet listed is not none");
  assert.deepEqual(r.runtimeTally([status("claude", "Claude"), { ...status("grok", "Grok"), isOut: true }, signedOut,
    status("gemini", "Gemini", false), installing]), { working: 1, total: 3 });
  assert.deepEqual(r.runtimeTally([{ ...status("claude", "Claude"), isOut: true }, signedOut]), { working: 0, total: 2 });
});

// Several accounts per runtime (#840): an added account's row is its own, under the runtime's.
test("runtimes: an added account's row is apart from the runtime's own, and named for both", () => {
  const rows = [
    { credentialKey: "claude:account:w1", accountID: "w1", accountName: "Work", state: {} },
    { credentialKey: "claude:sign-in", state: {} },
    { credentialKey: "codex:sign-in", state: {} },
  ];
  assert.equal(r.ownRow(rows, "claude").credentialKey, "claude:sign-in");
  assert.deepEqual(r.accountRows(rows, "claude").map((row) => row.credentialKey), ["claude:account:w1"]);
  assert.deepEqual(r.accountRows(rows, "codex"), []);
  assert.equal(r.rowTitle(rows[0], "Claude"), "Claude · Work");
  assert.equal(r.rowTitle(rows[1], "Claude"), "Claude");
  // A started session's label names its account the same way (#2259), never the runtime's own.
  const profiles = [{ id: "w1", runtimeID: "claude", name: "Work" }, { id: "h1", runtimeID: "codex", name: "Home" }];
  assert.equal(r.sessionRuntimeName("Claude", "claude", "w1", profiles), "Claude · Work");
  assert.equal(r.sessionRuntimeName("Claude", "claude", "h1", profiles), "Claude", "another runtime's");
  assert.equal(r.sessionRuntimeName("Claude", "claude", undefined, profiles), "Claude");
  assert.equal(r.sessionRuntimeName("Claude", "claude", "default", profiles), "Claude");
  assert.equal(r.accountState({ signedIn: false }), "Not signed in");
  assert.equal(r.accountState({ signedIn: true, signedInAs: "a@example.com" }), "Signed in as a@example.com");
});

test("runtimes: one the organisation does not allow cannot start, and says why (#998)", () => {
  const refused = { ...status("gemini", "Gemini"), setBy: { by: "organisation", rule: "runtimes", words: "Your organisation does not allow Gemini." } };
  const got = r.runtimeRuns([status("claude", "Claude"), refused]);
  assert.deepEqual([got.available, got.out, got.cannot].map((run) => run.map((s) => s.runtime.id)), [["claude"], [], ["gemini"]]);
  assert.equal(r.unavailableReason(refused), "Set by your organisation. Your organisation does not allow Gemini.");
});

// An org account as a member sees it (#999, slice 3): OrgAccountMemberWordsTests says the same.
const avail = { credentialKey: "claude:account:org:acme", entryID: "E", since: 0, status: { available: {} } };
const clock = (wire) => `t${wire}`;
const other = () => "Out since then";

test("org account: no plan limit, its tokens today, and out until its time", () => {
  assert.equal(r.orgAllowanceLine(avail, 12000, new Date(), clock, other), "Organisation · No plan limit · 12,000 tokens today");
  assert.equal(r.orgAllowanceLine(avail, undefined, new Date(), clock, other), "Organisation · No plan limit");
  const later = 2e9;
  const limited = { ...avail, status: { rateLimited: { until: later } } };
  assert.equal(r.orgAllowanceLine(limited, 5, new Date(0), clock, other), `Out until t${later} · 5 tokens today`);
  assert.equal(r.isOrgRow({ credentialKey: "claude:account:org:acme", accountID: "org:acme" }), true);
  assert.equal(r.isOrgRow({ credentialKey: "claude:account:w1", accountID: "w1" }), false);
});

test("org account: a cost says whose price it is, and the account says where it is from", () => {
  assert.equal(r.listPrice("claude"), "list price, as Claude reports it");
  assert.equal(r.priced({ accountID: "org:acme", runtimeID: "claude" }, "$0.42"), "$0.42 · list price, as Claude reports it");
  assert.equal(r.priced({ runtimeID: "claude" }, "$0.42"), "$0.42");
  const org = { id: "org:acme", runtimeID: "claude", name: "Acme", reach: { orgKey: { route: "acme" } }, source: "organisation", addedAt: 0, signedIn: true };
  assert.equal(r.accountState(org), "From your organisation");
});

test("account choices: the default, the own sign-in, what is sent and why a session must move", () => {
  const refused = { by: "organisation", rule: "runtimes.claude.reach", words: "Your organisation requires Claude to use Acme." };
  const list = [
    { id: "w1", runtimeID: "claude", name: "Work", reach: { signIn: { folder: "/a" } }, addedAt: 0, signedIn: true, setBy: refused },
    { id: "org:acme", runtimeID: "claude", name: "Acme", reach: { orgKey: { route: "acme" } }, source: "organisation", isDefault: true, addedAt: 0, signedIn: true },
  ];
  const policy = { runtimes: { claude: { reach: ["orgKey", "gateway"] } } };
  const c = r.accountChoices("claude", list, policy);
  assert.equal(c.shows, true);
  assert.equal(c.name(undefined), "Acme");
  assert.equal(c.ownChoice, "default");
  assert.equal(c.sent("default"), "default");
  assert.equal(c.sent("nope"), undefined);
  assert.equal(c.ownSetBy.words, "Your organisation requires Claude to use Acme.");
  assert.equal(c.moveReason("w1", true), refused.words);
  assert.equal(c.moveReason("org:gone", true), "Your organisation removed this way to the model.");
  assert.equal(c.moveReason("org:acme", true), undefined);
  assert.equal(c.moveReason("org:gone", false), undefined);
  assert.equal(r.accountChoices("codex", list).ownChoice, undefined);
  assert.equal(r.defaultAccountName, "Your Own Sign-In");
});

test("account words: Remove counts the sessions it stops and says it can't be undone (#2264)", () => {
  assert.equal(r.removeMessage(0, "the Mac"), "Nothing is running on it. Its sign-in is deleted from the Mac. This can’t be undone.");
  assert.equal(r.removeMessage(2, "the Mac"), "This stops 2 sessions mid-conversation. Its sign-in is deleted from the Mac. This can’t be undone.");
  const work = { id: "work", runtimeID: "claude", name: "Work", reach: { signIn: { folder: "/w" } }, signedIn: true };
  const agents = [{ runtimeID: "claude", accountID: "work", state: "running" }, { runtimeID: "claude", accountID: "work", state: "finished" },
    { runtimeID: "claude", state: "running" }];
  assert.equal(r.agentsHolding(agents, work).length, 1);
});

test("account words: a choice says it is not signed in, not usable or out (#2265)", () => {
  const now = new Date();
  const work = { id: "work", runtimeID: "claude", name: "Work", reach: { signIn: { folder: "/w" } }, signedIn: true, signedInAs: "a@b.c" };
  const row = (status, extra = {}) => ({ credentialKey: "claude:account:work", accountID: "work", state: { status, since: 0 }, ...extra });
  assert.equal(r.choiceNote({ ...work, signedIn: false }, undefined, now), "Not signed in");
  assert.equal(r.choiceNote(work, undefined, now), "a@b.c");
  assert.equal(r.choiceNote(work, row({ available: {} }), now), "a@b.c");
  assert.equal(r.choiceNote(work, row({ available: {} }, { unusable: "no key" }), now), "Not usable: no key");
  assert.match(r.choiceNote(work, row({ out: {} }), now), /^Out since /);
  assert.equal(r.choiceNote(undefined, undefined, now), undefined);
});
