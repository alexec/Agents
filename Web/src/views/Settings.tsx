// This browser's Settings (#846), opened from the sidebar's foot, in the chat's place: what the
// window has in Settings ▸ Sidebar, and Settings ▸ People (#994). Which smart groups are on is the person's,
// kept on their Mac and the same on every client (#1033). Machine providers are the control plane's (#1808).
// Machines lists each machine with its version, and the control plane's (#1748, #1759).
// Its sections are in the window's three groups by subject (#2157): This browser, Machines and Control plane.
// Backups are the person's Mac's, as the window's Settings ▸ Machines ▸ This Mac draws them (#1810), and each server's (#1815).
// Each section is a file of its own in ./settings, listed in ./settings/sections.ts (#2020).
import type { ComponentChildren } from "preact";
import type { Store } from "../model/store";
import { BackToList } from "./BackToList";
import { sectionsIn } from "./settings/sections";


/** Settings' groups by subject (#2157), as the window's rail and the Remote's Settings name them: this browser
 * (the window and the Remote say "This app"), the machines, and what the control plane keeps. A section added later
 * goes in its group. */
export const scopeTitles = { thisApp: "This browser", machines: "Machines", agentConfiguration: "Agent Configuration", controlPlane: "Control plane" } as const;

/** One group of Settings, under its heading. */
function Scope({ id, title, children }: { id: string; title: string; children: ComponentChildren }) {
  return (
    <section class="settings-scope" aria-labelledby={id}>
      <h2 class="scope-head" id={id}>{title}</h2>
      {children}
    </section>
  );
}

const scopeIDs = { thisApp: "settings-scope-app", machines: "settings-scope-machines", agentConfiguration: "settings-scope-agent-configuration", controlPlane: "settings-scope-control" } as const;

export function SettingsPage({ store, down = false }: { store: Store; down?: boolean }) {
  return (
    <section class="chat activity-page settings-page" aria-label="Settings">
      <header class="column-head"><BackToList /><h1>Settings</h1></header>
      <div class="scroll">
        <div class="activity-body settings-body">
          {(["thisApp", "machines", "agentConfiguration", "controlPlane"] as const).map((scope) => (
            <Scope key={scope} id={scopeIDs[scope]} title={scopeTitles[scope]}>
              {sectionsIn(scope, store).map(({ name, Section }) => <Section key={name} store={store} down={down} />)}
            </Scope>
          ))}
        </div>
      </div>
    </section>
  );
}
