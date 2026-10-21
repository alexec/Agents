// The control plane's three apps (#1804): the switcher at the top of the page (Workspace | Console |
// Reports), and the Console and Reports drawn in place of the sidebar and the chat: a list of
// pages on the left, the page on the right. The Console is the admins'; a member sees why not.
// The control plane checks each call's role itself; the page only leaves out what would be refused.
import type { ComponentChildren } from "preact";
import { useEffect } from "preact/hooks";
import { signal } from "@preact/signals";
import type { Store } from "../model/store";
import { go, route } from "../route";
import type { SubApp } from "../route";
import { CallFailed } from "../wire/link";
import { adminsOnly, appTitle, apps, consoleFoot, grouped, noRoles, notBuilt, openSection, sectionsOf } from "../model/console";
import type { AppName, Section } from "../model/console";
import { ReportsPage } from "./Reports";

/** Whether this person is an admin of the control plane: null until people/list answers. */
export const isAdmin = signal<boolean | null>(null);
/** Why the role is not known: a control plane before roles (#994), or none to ask. */
const roleProblem = signal<string | null>(null);

async function loadRole(store: Store) {
  try {
    isAdmin.value = (await store.link.call("people/list", {})).admin;
    roleProblem.value = null;
  } catch (error) {
    isAdmin.value = false;
    roleProblem.value = error instanceof CallFailed && error.code === -32601 ? noRoles : null;
  }
}

/** Workspace | Console | Reports, at the top of every page. Console is left out for a member. */
export function AppSwitcher({ store, down }: { store: Store; down: boolean }) {
  const changes = store.peopleChanges.value;
  useEffect(() => { if (!down) void loadRole(store); }, [changes, down]);
  const current: AppName = route.value.app ?? "workspace";
  const shown = apps.filter((a) => a !== "console" || isAdmin.value || current === "console");
  return (
    <nav class="app-switcher" aria-label="Apps">
      <div class="segmented" role="tablist">
        {shown.map((a) => (
          <button key={a} role="tab" aria-selected={current === a} class={current === a ? "on" : ""}
            onClick={() => go(a === "workspace" ? {} : { app: a })}>{appTitle[a]}</button>
        ))}
      </div>
    </nav>
  );
}

/** The Console or Reports: its pages on the left, the one open on the right. */
export function SubAppPage({ store, app, down }: { store: Store; app: SubApp; down: boolean }) {
  const open = openSection(app, route.value.section);
  const gated = app === "console" && isAdmin.value !== true;
  return (
    <div class="columns sub-app" aria-busy={down}>
      <nav class="projects sub-app-list" aria-label={appTitle[app]}>
        {grouped(sectionsOf(app)).map(([group, list]) => (
          <div key={group} class="sub-app-group">
            <h2 class="section-head">{group}</h2>
            {list.map((s) => (
              <button key={s.id} type="button" class={`sub-app-row${s.id === open.id ? " on" : ""}`} disabled={!s.built || gated}
                aria-current={s.id === open.id ? "page" : undefined} title={s.built ? s.about : notBuilt}
                onClick={() => go({ app, section: s.id })}>{s.title}</button>
            ))}
          </div>
        ))}
      </nav>
      <section class="chat activity-page sub-app-page" aria-label={open.title}>
        <header class="column-head"><h1>{open.title}</h1></header>
        <div class="scroll">
          <div class="activity-body">
            {gated
              ? <p class="hint">{isAdmin.value === null ? "Loading…" : roleProblem.value ?? adminsOnly}</p>
              : app === "console" ? <ConsoleSection store={store} section={open} down={down} />
              : <ReportsPage store={store} section={open} down={down} />}
          </div>
        </div>
      </section>
    </div>
  );
}

function ConsoleSection({ section }: { store: Store; section: Section; down: boolean }) {
  switch (section.id) {
    default: return <Overview />;
  }
}

/** The Console's first page: each of its pages, what it is for, and which are still to come. */
function Overview() {
  return (
    <>
      <ul class="console-cards">
        {sectionsOf("console").filter((s) => s.id !== "overview").map((s) => (
          <Card key={s.id} section={s}>
            {s.built
              ? <button type="button" class="link" onClick={() => go({ app: "console", section: s.id })}>Open</button>
              : <span class="quiet small">{notBuilt}</span>}
          </Card>
        ))}
      </ul>
      <p class="hint">{consoleFoot}</p>
    </>
  );
}

function Card({ section, children }: { section: Section; children: ComponentChildren }) {
  return (
    <li class="console-card">
      <span class="strong">{section.title}</span>
      <span class="quiet small">{section.about}</span>
      {children}
    </li>
  );
}
