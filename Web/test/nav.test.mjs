// The control plane web page by section (#2141): the bar, each section's pages, who sees what, and
// every address from before it at its new place.
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const n = await load("src/model/nav.ts");

test("a member's bar has six sections, an admin's eight", () => {
  assert.deepEqual(n.sectionsShown(false, "overview").map((s) => n.navTitle[s]),
    ["Overview", "Agents", "Machines", "Workflows", "Reports", "Settings"]);
  assert.deepEqual(n.sectionsShown(null, "agents"), n.sectionsShown(false, "agents"), "not known yet is a member's");
  assert.deepEqual(n.sectionsShown(true, "overview").map((s) => n.navTitle[s]),
    ["Overview", "Agents", "Machines", "Workflows", "Reports", "Requests", "People", "Settings"]);
  assert.ok(n.sectionsShown(false, "people").includes("people"), "a member who opens People by its address sees where they are");
});

test("a member sees no admin page in a list, and opens the first they may use", () => {
  assert.deepEqual(n.pagesShown("settings", false).map((p) => p.id), ["settings"]);
  assert.deepEqual(n.pagesShown("workflows", false).map((p) => p.id), ["workflows"]);
  assert.deepEqual(n.pagesShown("agents", false).map((p) => p.id), ["projects"]);
  assert.ok(n.pagesShown("reports", false).every((p) => p.id !== "audit"));
  assert.deepEqual(n.pagesShown("settings", false, "policy").map((p) => p.id), ["settings", "policy"], "and the one open");
  assert.equal(n.openPage("people", undefined, false).id, "people");
  assert.equal(n.gated(n.openPage("people", undefined, false), false), true);
  assert.equal(n.gated(n.openPage("people", undefined, true), true), false);
  assert.equal(n.openPage("machines", "nowhere", true).id, "machines");
  assert.equal(n.openPage("reports", undefined, false).id, "spend");
});

test("every page has a title, and its group headings come in order", () => {
  for (const s of n.navSections) for (const p of n.navPages[s]) assert.ok(p.title, `${s}/${p.id}`);
  assert.deepEqual(n.groupedPages(n.navPages.reports).map(([g]) => g), ["Reports", "Saved", "Yours", "Records"]);
  assert.deepEqual(n.groupedPages(n.navPages.machines).map(([g]) => g), ["Machines", "On them"]);
});

test("each section is its own address, and #/ is the Overview", async () => {
  globalThis.location = { hash: "" };
  globalThis.addEventListener = () => {};
  try {
    const r = await load("src/route.ts");
    assert.deepEqual(r.parseRoute("#/"), {});
    assert.equal(r.sectionOf(r.parseRoute("#/")), "overview");
    assert.deepEqual(r.parseRoute("#/agents"), { nav: "agents" });
    assert.deepEqual(r.parseRoute("#/agents/live"), { nav: "agents", section: "live" });
    assert.deepEqual(r.parseRoute("#/machines/runtimes"), { nav: "machines", section: "runtimes" });
    assert.deepEqual(r.parseRoute("#/reports/spend"), { nav: "reports", section: "spend" });
    assert.equal(r.routeHash({ nav: "settings", section: "policy" }, undefined), "#/settings/policy");
    assert.equal(r.routeHash({}, undefined), "#/");
    assert.deepEqual(r.parseRoute(r.routeHash({ nav: "reports", section: "a b" }, undefined)), { nav: "reports", section: "a b" });
    // A session is in Agents, at the address it always had: every notice and link still opens it.
    const chat = { host: "mac", folder: "file:///w/a", session: "S1" };
    assert.equal(r.routeHash(chat, undefined), "#/h/mac/p/file%3A%2F%2F%2Fw%2Fa/s/S1");
    assert.equal(r.sectionOf(r.parseRoute(r.routeHash(chat, undefined))), "agents");
  } finally {
    delete globalThis.location;
    delete globalThis.addEventListener;
  }
});

test("an address from before #2141 opens its page's new place", async () => {
  globalThis.location = { hash: "" };
  globalThis.addEventListener = () => {};
  try {
    const r = await load("src/route.ts");
    const moved = {
      "#/console": {}, "#/console/overview": {},
      "#/console/live": { nav: "agents", section: "live" }, "#/console/projects": { nav: "agents", section: "projects" },
      "#/console/machines": { nav: "machines", section: "machines" }, "#/console/workflows": { nav: "workflows", section: "team" },
      "#/console/audit": { nav: "reports", section: "audit" }, "#/console/requests": { nav: "requests" },
      "#/console/people": { nav: "people", section: "people" }, "#/console/signIn": { nav: "people", section: "signIn" },
      "#/console/policy": { nav: "settings", section: "policy" }, "#/console/readApi": { nav: "settings", section: "readApi" },
      "#/a/runtimes": { nav: "machines", section: "runtimes" }, "#/a/mcp": { nav: "machines", section: "mcp" },
      "#/a/events": { nav: "reports", section: "events" }, "#/a/milestones": { nav: "reports", section: "milestones" },
      "#/a/tokens": { nav: "reports", section: "usage" },
    };
    for (const [old, now] of Object.entries(moved)) {
      assert.deepEqual(r.parseRoute(old), now, old);
      assert.equal(r.isOldAddress(old), true, old);
    }
    assert.equal(r.usageAsked.value, "tokens", "Usage opens on the pane the old address named");
    assert.equal(r.isOldAddress("#/reports/spend"), false);
    assert.equal(r.isOldAddress("#/h/mac/p/x"), false);
    // Every page an old address names is a page of its section.
    for (const now of Object.values(moved)) {
      if (now.nav && now.section) assert.ok(n.navPages[now.nav].some((p) => p.id === now.section), `${now.nav}/${now.section}`);
    }
  } finally {
    delete globalThis.location;
    delete globalThis.addEventListener;
  }
});

test("Agents' state filter keeps the sessions in that state", async () => {
  const f = await load("src/model/agentFilters.ts");
  const agent = (state, extra = {}) => ({ id: state, state, createdAt: 0, labels: [], ...extra });
  assert.equal(f.keptByState(agent("running"), "any"), true);
  assert.equal(f.keptByState(agent("running"), "working"), true);
  assert.equal(f.keptByState(agent("running"), "needsYou"), false);
  assert.equal(f.keptByState(agent("finished"), "done"), true);
  assert.equal(f.keptByState(agent("finished"), "working"), false);
});
